import json, os, re, base64, hashlib, secrets
from datetime import datetime, timedelta
from pathlib import Path
from fastapi import FastAPI, Request, Form, HTTPException
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.middleware.sessions import SessionMiddleware
from app.database import execute_procedure, test_connection
from app.security import verify_password, require_user
from app.procedure_catalog import ALLOWED_PROCEDURES

ROOT = Path(__file__).resolve().parent
app = FastAPI(title="EVN-03 | Cổng theo dõi tiêu thụ năng lượng")
app.add_middleware(SessionMiddleware, secret_key=os.getenv("SESSION_SECRET", "dev-only-change-me"), same_site="lax", https_only=False)
app.mount("/static", StaticFiles(directory=ROOT / "static"), name="static")
templates = Jinja2Templates(directory=ROOT / "templates")

MODULES = [
 {"key":"dashboard","title":"Tổng quan & Báo cáo","uc":"UC10","icon":"▦","proc":"usp_Dash_Summary","procs":["usp_Dash_Summary","usp_Dash_LoadProfile","usp_Dash_ByFloor","usp_Dash_Heatmap","usp_Dash_MeterStatus","usp_Report_Consumption","usp_Report_Log","usp_Report_History"]},
 {"key":"spaces","title":"Không gian tòa nhà","uc":"UC01","icon":"⌂","proc":"usp_Building_List","procs":["usp_Building_Save","usp_Building_List","usp_Floor_Save","usp_Floor_List","usp_Room_Save","usp_Room_List","usp_FloorPlan_Get"]},
 {"key":"meters","title":"Quản lý công tơ","uc":"UC01","icon":"◉","proc":"usp_Meter_List","procs":["usp_Meter_Save","usp_Meter_List","usp_Meter_Lookup","usp_Meter_SetStatus","usp_Meter_Delete","usp_EnergyType_List"]},
 {"key":"readings","title":"Thu thập & Chỉ số","uc":"UC02","icon":"⌁","proc":"usp_Telemetry_List","procs":["usp_Telemetry_IngestBatch","usp_Telemetry_ManualEntry","usp_Telemetry_List","usp_Aggregate_Run","usp_Aggregate_List","usp_IngestLog_List"]},
 {"key":"quotas","title":"Định mức tiêu thụ","uc":"UC03","icon":"▤","proc":"usp_Quota_List","procs":["usp_Quota_Save","usp_Quota_List","usp_Quota_SetActive","usp_Quota_Delete"]},
 {"key":"monitor","title":"Giám sát & Cảnh báo","uc":"UC04","icon":"◷","proc":"usp_Alert_List","procs":["usp_Monitor_Scan","usp_Monitor_Status","usp_Alert_List","usp_Alert_SetStatus"]},
 {"key":"data-anomalies","title":"Bất thường dữ liệu","uc":"UC05","icon":"⚑","proc":"usp_DQ_List","procs":["usp_DQ_Scan","usp_DQ_List","usp_DQ_ScanRuns_List"]},
 {"key":"consumption-anomalies","title":"Bất thường tiêu thụ","uc":"UC06","icon":"⌁","proc":"usp_CA_List","procs":["usp_Baseline_Compute","usp_CA_Scan","usp_CA_Series","usp_CA_List","usp_CA_SetStatus"]},
 {"key":"transformations","title":"Làm sạch & Audit Log","uc":"UC07","icon":"⟳","proc":"usp_Audit_List","procs":["usp_Transform_Compute","usp_Transform_Preview","usp_Transform_Apply","usp_Transform_PreviewJson","usp_Transform_ApplyJson","usp_Anomaly_ConfirmValid","usp_Transform_Methods_List","usp_Audit_List"]},
 {"key":"saving-plans","title":"Kế hoạch tiết kiệm","uc":"UC08","icon":"♧","proc":"usp_Plan_List","procs":["usp_Plan_Save","usp_Plan_RefreshStatus","usp_Plan_List","usp_Plan_SetStatus","usp_Plan_Delete","usp_Solution_Save","usp_Solution_Delete","usp_Solution_List"]},
 {"key":"kpi","title":"KPI tiết kiệm","uc":"UC09","icon":"◫","proc":"usp_KPI_Summary","procs":["usp_KPI_Calculate","usp_KPI_Series","usp_KPI_History","usp_KPI_Summary"]},
 {"key":"users","title":"Tài khoản & Phân quyền","uc":"UC11","icon":"♙","proc":"usp_User_List","procs":["usp_User_List","usp_Role_List","usp_Permission_Matrix","usp_RolePermission_Save","usp_LoginHistory_List"]},
 {"key":"email","title":"Hộp thư thông báo","uc":"UC11","icon":"✉","proc":"usp_Email_List","procs":["usp_Email_List","usp_Email_MarkResult"]},
]
for module in MODULES:
    module["procs"] = [p for p in module["procs"] if p in ALLOWED_PROCEDURES]


CRUD_SECTIONS = {
 "spaces": [
  {"title":"Tòa nhà", "delete_proc":"usp_Building_Delete", "delete_key":"BuildingId", "list_proc":"usp_Building_List", "list_params":{"OnlyActive":False}, "save_proc":"usp_Building_Save", "fields":[
   ("BuildingId","ID khi cập nhật (để trống nếu thêm mới)","number",False,None),("BuildingCode","Mã tòa nhà","text",True,None),("BuildingName","Tên tòa nhà","text",True,None),("Address","Địa chỉ","text",False,None),("IsActive","Đang hoạt động","select",True,[("true","Có"),("false","Không")])]},
  {"title":"Tầng / mặt bằng", "delete_proc":"usp_Floor_Delete", "delete_key":"FloorId", "list_proc":"usp_Floor_List", "list_params":{}, "save_proc":"usp_Floor_Save", "fields":[
   ("FloorId","ID tầng khi cập nhật","number",False,None),("BuildingId","Tòa nhà","select",True,"buildings"),("FloorNo","Số tầng","number",True,None),("FloorName","Tên tầng","text",True,None),
   ("MinX","X nhỏ nhất (m)","number",True,None),("MinY","Y nhỏ nhất (m)","number",True,None),("MaxX","X lớn nhất (m)","number",True,None),("MaxY","Y lớn nhất (m)","number",True,None)]},
  {"title":"Phòng", "delete_proc":"usp_Room_Delete", "delete_key":"RoomId", "list_proc":"usp_Room_List", "list_params":{}, "save_proc":"usp_Room_Save", "fields":[
   ("RoomId","ID phòng khi cập nhật","number",False,None),("FloorId","Tầng","select",True,"floors"),("RoomCode","Mã phòng","text",True,None),("RoomName","Tên phòng","text",True,None),
   ("MinX","X nhỏ nhất (m)","number",True,None),("MinY","Y nhỏ nhất (m)","number",True,None),("MaxX","X lớn nhất (m)","number",True,None),("MaxY","Y lớn nhất (m)","number",True,None)]}
 ],
 "meters": [{"title":"Công tơ", "delete_proc":"usp_Meter_Delete", "delete_key":"MeterId", "list_proc":"usp_Meter_List", "list_params":{}, "save_proc":"usp_Meter_Save", "fields":[
  ("MeterId","ID công tơ khi cập nhật","number",False,None),("MeterCode","Mã công tơ","text",True,None),("MeterName","Tên công tơ","text",True,None),
  ("EnergyTypeId","Loại năng lượng","select",True,"energy_types"),("Manufacturer","Nhà sản xuất","text",False,None),("Model","Model","text",False,None),("SerialNo","Số serial","text",False,None),
  ("Specification","Thông số kỹ thuật","text",False,None),("MaxValuePerInterval","Ngưỡng tối đa mỗi chu kỳ","number",False,None),("IntervalMinutes","Chu kỳ đo (phút)","select",True,[("15","15"),("30","30"),("60","60")]),
  ("FloorId","Tầng","select",True,"floors"),("RoomId","Phòng (không bắt buộc)","select",False,"rooms"),("LocX","Tọa độ X (m)","number",True,None),("LocY","Tọa độ Y (m)","number",True,None),
  ("InstallDate","Ngày lắp đặt","date",False,None),("Status","Trạng thái","select",True,[("ACTIVE","Hoạt động"),("INACTIVE","Ngưng hoạt động"),("FAULTY","Bị lỗi")])]}],
 "readings": [{"title":"Ghi nhận chỉ số thủ công", "list_proc":"usp_Telemetry_List", "list_params":{"Top":200}, "save_proc":"usp_Telemetry_ManualEntry", "fields":[
  ("MeterId","Công tơ","select",True,"meters"),("ReadingTime","Thời điểm ghi nhận","datetime-local",True,None),("Value","Giá trị chỉ số","number",True,None)]}],
 "quotas": [{"title":"Định mức tiêu thụ", "delete_proc":"usp_Quota_Delete", "delete_key":"QuotaId", "list_proc":"usp_Quota_List", "list_params":{"ActiveOnly":False}, "save_proc":"usp_Quota_Save", "fields":[
  ("QuotaId","ID định mức khi cập nhật","number",False,None),("QuotaCode","Mã định mức","text",True,None),("BuildingId","Tòa nhà","select",True,"buildings"),("FloorId","Tầng (để trống nếu áp dụng toàn tòa)","select",False,"floors"),("RoomId","Phòng (không bắt buộc)","select",False,"rooms"),
  ("EnergyTypeId","Loại năng lượng","select",True,"energy_types"),("PeriodType","Chu kỳ","select",True,[("HOUR","Giờ"),("DAY","Ngày"),("MONTH","Tháng")]),("QuotaValue","Giá trị định mức","number",True,None),("WarningPercent","Ngưỡng cảnh báo (%)","number",True,None),
  ("EffectiveFrom","Ngày bắt đầu","date",True,None),("EffectiveTo","Ngày kết thúc (không bắt buộc)","date",False,None),("TimeFrom","Giờ bắt đầu","time",True,None),("TimeTo","Giờ kết thúc","time",True,None),
  ("IsActive","Đang áp dụng","select",True,[("true","Có"),("false","Không")]),("Note","Ghi chú","text",False,None)]}]
}

LOOKUP_PROCS = {
 "buildings": ("usp_Building_List", {"OnlyActive":False}, "BuildingId", "BuildingName"),
 "floors": ("usp_Floor_List", {}, "FloorId", "FloorName"),
 "rooms": ("usp_Room_List", {}, "RoomId", "RoomName"),
 "energy_types": ("usp_EnergyType_List", {}, "EnergyTypeId", "Name"),
 "meters": ("usp_Meter_Lookup", {"ActiveOnly":True}, "MeterId", "Display"),
 "plans": ("usp_Plan_List", {"Status":None,"BuildingId":None}, "PlanId", "PlanCode"),
}


def build_lookups():
    raw_map = {}
    for name, (proc, params, vk, lk) in LOOKUP_PROCS.items():
        if proc in ALLOWED_PROCEDURES:
            rs = execute_procedure(proc, params)
            raw_map[name] = rs[0] if rs else []
        else:
            raw_map[name] = []

    floor_info = {}
    for r in raw_map.get("floors", []):
        floor_info[r.get("FloorId")] = {
            "building_id": r.get("BuildingId"),
            "building_name": r.get("BuildingName") or "",
            "floor_name": r.get("FloorName") or "",
        }

    lookups = {}
    for name, (proc, params, vk, lk) in LOOKUP_PROCS.items():
        items = []
        for r in raw_map.get(name, []):
            val = r.get(vk)
            lbl = str(r.get(lk) or "")
            b_id = r.get("BuildingId")
            f_id = r.get("FloorId")
            if name == "floors":
                bname = r.get("BuildingName")
                lbl = f"{bname} · {lbl}" if bname else lbl
            elif name == "rooms":
                finfo = floor_info.get(f_id, {})
                b_id = finfo.get("building_id")
                bname = finfo.get("building_name")
                fname = r.get("FloorName") or finfo.get("floor_name")
                rcode = r.get("RoomCode")
                room_part = f"{rcode} - {lbl}" if rcode and rcode not in lbl else lbl
                prefix = " · ".join(p for p in (bname, fname) if p)
                lbl = f"{prefix} · {room_part}" if prefix else room_part
            items.append({
                "value": val,
                "label": lbl,
                "building_id": b_id if b_id is not None else "",
                "floor_id": f_id if f_id is not None else "",
            })
        lookups[name] = items
    return lookups


WORKFLOWS = {
 "monitor": {
  "description": "Đối chiếu tiêu thụ dữ liệu sạch với định mức; tạo cảnh báo VÀNG/ĐỎ và gửi email cho Quản lý năng lượng.",
  "datasets": [
   {"title":"Trạng thái giám sát theo định mức", "proc":"usp_Monitor_Status", "params":{"BuildingId":None,"EnergyTypeId":None,"AsOf":None}},
   {"title":"Danh sách cảnh báo", "proc":"usp_Alert_List", "params":{"Status":None,"Severity":None,"From":None,"To":None,"Top":300}},
  ],
  "actions": [
   {"key":"scan","title":"Quét giám sát ngay", "proc":"usp_Monitor_Scan", "description":"Tính mức tiêu thụ theo các định mức đang hoạt động trong 3 ngày gần nhất.", "fields":[("AsOf","Thời điểm đối chiếu","datetime-local",False,None),("LookbackDays","Số ngày nhìn lại","number",True,"3")]},
   {"key":"filter_alerts","title":"Lọc cảnh báo", "proc":"usp_Alert_List", "description":"Lọc theo trạng thái và mức độ cảnh báo.", "fields":[("Status","Trạng thái","select",False,[("NEW","Mới"),("ACKNOWLEDGED","Đã tiếp nhận"),("RESOLVED","Đã xử lý")]),("Severity","Mức độ","select",False,[("YELLOW","Vàng"),("RED","Đỏ")]),("Top","Số dòng tối đa","number",True,"300")]},
   {"key":"handle_alert","title":"Cập nhật trạng thái cảnh báo", "proc":"usp_Alert_SetStatus", "description":"Đóng cảnh báo bắt buộc ghi chú biện pháp xử lý.", "fields":[("AlertId","Mã cảnh báo","number",True,None),("Status","Trạng thái mới","select",True,[("ACKNOWLEDGED","Đã tiếp nhận"),("RESOLVED","Đã xử lý")]),("Note","Ghi chú xử lý","text",False,None)]},
  ]
 },
 "data-anomalies": {
  "description": "Quét dữ liệu thô để phát hiện chỉ số âm, mốc bị khuyết, nhảy vọt và công tơ mất tín hiệu. Đây là lỗi kỹ thuật dữ liệu, tách biệt với bất thường tiêu thụ UC06.",
  "datasets": [
   {"title":"Danh sách bất thường dữ liệu", "proc":"usp_DQ_List", "params":{"Status":"OPEN","MeterId":None,"Type":None,"From":None,"To":None,"Top":500}},
   {"title":"Lịch sử các lần quét chất lượng", "proc":"usp_DQ_ScanRuns_List", "params":{"Top":50}},
  ],
  "actions": [
   {"key":"scan","title":"Chạy Data Quality Scan", "proc":"usp_DQ_Scan", "description":"Quét khoảng thời gian được chọn. Có thể bật quét lại hoặc tổng hợp lại sau khi kiểm tra chất lượng.", "fields":[("MeterId","Công tơ (để trống = tất cả)","lookup:meters",False,None),("From","Từ thời điểm","datetime-local",False,None),("To","Đến thời điểm","datetime-local",False,None),("Mode","Chế độ quét","select",True,[("MANUAL","Thủ công"),("SCHEDULED","Theo lịch")]),("Rescan","Quét lại dữ liệu đã VALID","select",True,[("false","Không"),("true","Có")]),("Aggregate","Tổng hợp lại sau quét","select",True,[("true","Có"),("false","Không")])]},
   {"key":"filter","title":"Lọc bất thường", "proc":"usp_DQ_List", "description":"Lọc danh sách theo trạng thái, công tơ và loại lỗi.", "fields":[("Status","Trạng thái","select",False,[("OPEN","Chờ xử lý"),("RESOLVED","Đã xử lý"),("IGNORED","Bỏ qua")]),("MeterId","Công tơ","lookup:meters",False,None),("Type","Loại bất thường","select",False,[("NEGATIVE","Chỉ số âm"),("MISSING","Khuyết dữ liệu"),("SPIKE","Nhảy vọt"),("NO_SIGNAL","Mất tín hiệu")]),("Top","Số dòng tối đa","number",True,"500")]},
  ]
 },
 "consumption-anomalies": {
  "description": "Phân tích dữ liệu đã đạt chất lượng (IsComplete = 1), xây dựng Baseline theo ngày thường/cuối tuần và giờ trong ngày, nhận diện ngoài giờ, quá tải hoặc rò rỉ.",
  "datasets": [
   {"title":"Danh sách bất thường tiêu thụ", "proc":"usp_CA_List", "params":{"Status":"NEW","MeterId":None,"From":None,"To":None,"Top":300}},
  ],
  "actions": [
   {"key":"baseline","title":"Tính đường cơ sở Baseline", "proc":"usp_Baseline_Compute", "description":"Tính trung bình và độ lệch chuẩn từ các khung giờ hợp lệ trước thời gian phân tích.", "fields":[("MeterId","Công tơ (để trống = tất cả)","lookup:meters",False,None),("From","Từ ngày","date",False,None),("To","Đến ngày","date",False,None)]},
   {"key":"scan","title":"Quét bất thường tiêu thụ", "proc":"usp_CA_Scan", "description":"So sánh dữ liệu sạch với Baseline; bỏ qua giờ chưa đủ chất lượng và gửi email nếu có phát hiện mới.", "fields":[("MeterId","Công tơ (để trống = tất cả)","lookup:meters",False,None),("From","Từ thời điểm","datetime-local",False,None),("To","Đến thời điểm","datetime-local",False,None)]},
   {"key":"filter","title":"Lọc bất thường tiêu thụ", "proc":"usp_CA_List", "description":"Lọc theo trạng thái và công tơ.", "fields":[("Status","Trạng thái","select",False,[("NEW","Mới"),("CONFIRMED","Đã xác nhận"),("PLANNED","Có kế hoạch"),("CLOSED","Đã đóng")]),("MeterId","Công tơ","lookup:meters",False,None),("Top","Số dòng tối đa","number",True,"300")]},
   {"key":"handle","title":"Xử lý bất thường tiêu thụ", "proc":"usp_CA_SetStatus", "description":"Chọn PLANNED phải ghi rõ hoạt động đã có kế hoạch.", "fields":[("CAnomalyId","Mã bất thường","number",True,None),("Status","Trạng thái mới","select",True,[("CONFIRMED","Xác nhận bất thường"),("PLANNED","Hoạt động có kế hoạch"),("CLOSED","Đóng")]),("Note","Ghi chú / hoạt động có kế hoạch","text",False,None)]},
   {"key":"series","title":"Xem chuỗi tiêu thụ và Baseline", "proc":"usp_CA_Series", "description":"Đối chiếu thực tế, Baseline, ngưỡng trên và cùng khung giờ tuần trước.", "fields":[("MeterId","Công tơ","lookup:meters",True,None),("From","Từ thời điểm","datetime-local",True,None),("To","Đến thời điểm","datetime-local",True,None)]},
  ]
 },
 "transformations": {
  "description": "Làm sạch các bản ghi lỗi từ UC05. Bắt buộc xem trước kết quả trước khi áp dụng (BR06); thao tác áp dụng được ghi Audit Log bất biến, gồm giá trị cũ/mới, người thực hiện, thời gian, công thức và lý do.",
  "datasets": [
   {"title":"Bản ghi lỗi đang chờ xử lý (UC05)","proc":"usp_DQ_List","params":{"Status":"OPEN","MeterId":None,"Type":None,"From":None,"To":None,"Top":300}},
   {"title":"Phương pháp biến đổi đang hoạt động","proc":"usp_Transform_Methods_List","params":{}},
   {"title":"Audit Log gần nhất","proc":"usp_Audit_List","params":{"MeterId":None,"From":None,"To":None,"UserId":None,"ActionType":None,"Top":100}}
  ],
  "actions": [
   {"key":"preview","title":"Bước 1 – Xem trước (Preview)","proc":"usp_Transform_PreviewJson","description":"Nhập RawId từ danh sách lỗi, chọn phương pháp và tham số. Preview chỉ tính thử, KHÔNG ghi dữ liệu.","fields":[("RawIds","Danh sách RawId (phân cách bằng dấu phẩy)","text",True,None),("MethodCode","Phương pháp","select",True,[("LINEAR_INTERP","Nội suy tuyến tính"),("MOVING_AVG","Trung bình động"),("NOISE_FILTER","Lọc nhiễu (trung vị)"),("MEAN_DEFAULT","Trung bình cùng giờ")]),("Window","Tham số cửa sổ (1–60)","number",True,"2")]},
   {"key":"apply","title":"Bước 2 – Xác nhận áp dụng (Apply)","proc":"usp_Transform_ApplyJson","description":"Chỉ thực hiện nếu phiên hiện tại đã Preview đúng cùng danh sách RawId, phương pháp và tham số trong 20 phút. Sau khi áp dụng, Audit Log được ghi vĩnh viễn.","fields":[("RawIds","Danh sách RawId đã Preview","text",True,None),("MethodCode","Phương pháp giống Preview","select",True,[("LINEAR_INTERP","Nội suy tuyến tính"),("MOVING_AVG","Trung bình động"),("NOISE_FILTER","Lọc nhiễu (trung vị)"),("MEAN_DEFAULT","Trung bình cùng giờ")]),("Window","Tham số giống Preview","number",True,"2"),("Reason","Lý do điều chỉnh (bắt buộc)","text",True,None)]},
   {"key":"confirm_valid","title":"Xác nhận dữ liệu bất thường là đúng","proc":"usp_Anomaly_ConfirmValid","description":"Chỉ áp dụng cho bất thường có thể xác nhận là dữ liệu thực tế; SQL từ chối NEGATIVE/MISSING. Bắt buộc ghi chú.","fields":[("AnomalyId","Mã bất thường (AnomalyId)","number",True,None),("Note","Lý do xác nhận","text",True,None)]},
   {"key":"audit_filter","title":"Tra cứu Audit Log","proc":"usp_Audit_List","description":"Lọc lịch sử thao tác; Audit Log không cho phép sửa hoặc xóa.","fields":[("MeterId","Công tơ (không bắt buộc)","lookup:meters",False,None),("From","Từ thời gian","datetime-local",False,None),("To","Đến thời gian","datetime-local",False,None),("ActionType","Loại thao tác","select",False,[("TRANSFORM","Biến đổi"),("CONFIRM_VALID","Xác nhận đúng")]),("Top","Số dòng tối đa","number",True,"200")]}
  ]
 },
 "saving-plans": {
  "description": "Tạo và quản lý kế hoạch tiết kiệm theo tòa nhà/tầng/phòng và loại năng lượng. BR07: mục tiêu phải lớn hơn 0% và không vượt quá 100%; SQL tự tính khoảng Baseline trước ngày bắt đầu.",
  "datasets": [{"title":"Danh sách kế hoạch tiết kiệm","proc":"usp_Plan_List","params":{"Status":None,"BuildingId":None}}],
  "actions": [
   {"key":"save_plan","title":"Tạo / cập nhật kế hoạch","proc":"usp_Plan_Save","description":"Để cập nhật, nhập PlanId. Mã kế hoạch không đổi khi sửa; phạm vi có ràng buộc nếu đã phát sinh KPI.","fields":[("PlanId","PlanId (để trống nếu tạo mới)","number",False,None),("PlanCode","Mã kế hoạch","text",True,None),("PlanName","Tên kế hoạch","text",True,None),("BuildingId","Tòa nhà","lookup:buildings",True,None),("FloorId","Tầng (không bắt buộc)","lookup:floors",False,None),("RoomId","Phòng (không bắt buộc)","lookup:rooms",False,None),("EnergyTypeId","Loại năng lượng","lookup:energy_types",True,None),("TargetPercent","Mục tiêu tiết kiệm (%) – 0 < x <= 100","decimal",True,None),("StartDate","Ngày bắt đầu","date",True,None),("EndDate","Ngày kết thúc","date",True,None),("BaselineDays","Số ngày Baseline (7–365)","number",True,"28"),("Description","Mô tả","text",False,None)]},
   {"key":"filter_plans","title":"Lọc danh sách kế hoạch","proc":"usp_Plan_List","description":"Lọc theo trạng thái hoặc tòa nhà.","fields":[("Status","Trạng thái","select",False,[("RUNNING","Đang thực hiện"),("COMPLETED","Hoàn thành"),("CANCELLED","Đã hủy")]),("BuildingId","Tòa nhà","lookup:buildings",False,None)]},
   {"key":"set_plan_status","title":"Đổi trạng thái kế hoạch","proc":"usp_Plan_SetStatus","description":"Chuyển kế hoạch sang RUNNING, COMPLETED hoặc CANCELLED.","fields":[("PlanId","PlanId","number",True,None),("Status","Trạng thái mới","select",True,[("RUNNING","Đang thực hiện"),("COMPLETED","Hoàn thành"),("CANCELLED","Đã hủy")])]},
   {"key":"delete_plan","title":"Xóa kế hoạch","proc":"usp_Plan_Delete","description":"Chỉ xóa được khi kế hoạch chưa phát sinh KPI; nếu đã có KPI hãy chuyển trạng thái Hủy.","fields":[("PlanId","PlanId cần xóa","number",True,None)]},
   {"key":"save_solution","title":"Thêm / cập nhật giải pháp","proc":"usp_Solution_Save","description":"Nhập SolutionId nếu cập nhật; phải chọn PlanId tồn tại.","fields":[("SolutionId","SolutionId (để trống nếu thêm mới)","number",False,None),("PlanId","Kế hoạch","lookup:plans",True,None),("SolutionName","Tên giải pháp","text",True,None),("Description","Mô tả","text",False,None),("ExpectedSavingPercent","Tiết kiệm dự kiến (%)","decimal",False,None),("Status","Trạng thái","select",True,[("PLANNED","Đã lên kế hoạch"),("IN_PROGRESS","Đang thực hiện"),("DONE","Hoàn thành")]),("AssignedTo","Người phụ trách","text",False,None),("DueDate","Hạn hoàn thành","date",False,None)]},
   {"key":"list_solutions","title":"Xem giải pháp của kế hoạch","proc":"usp_Solution_List","description":"Liệt kê các giải pháp theo PlanId.","fields":[("PlanId","PlanId","number",True,None)]},
   {"key":"delete_solution","title":"Xóa giải pháp","proc":"usp_Solution_Delete","description":"Xóa giải pháp theo SolutionId.","fields":[("SolutionId","SolutionId cần xóa","number",True,None)]}
  ]
 },
 "kpi": {
  "description": "Tính và theo dõi hiệu quả tiết kiệm. Baseline phân biệt ngày thường/cuối tuần; chỉ ngày có đủ dữ liệu sạch của toàn bộ công tơ trong phạm vi mới được tính (BR08). KPI gồm kWh tiết kiệm, %, chi phí giảm, mức đạt mục tiêu và cảnh báo tiến độ.",
  "datasets": [{"title":"Tổng hợp KPI mới nhất theo kế hoạch","proc":"usp_KPI_Summary","params":{}}],
  "actions": [
   {"key":"calculate","title":"Tính KPI cho kế hoạch","proc":"usp_KPI_Calculate","description":"Tính KPI đến ngày hiện tại hoặc ngày AsOf được chọn; mỗi lần tính được lưu thành một dòng lịch sử.","fields":[("PlanId","Kế hoạch","lookup:plans",True,None),("AsOf","Đánh giá đến ngày (để trống = hôm nay)","date",False,None)]},
   {"key":"series","title":"Xem chuỗi Baseline – Thực tế – Mục tiêu","proc":"usp_KPI_Series","description":"Trả về chuỗi theo ngày để đối chiếu thực tế, kỳ vọng nếu không tiết kiệm và mức mục tiêu.","fields":[("PlanId","Kế hoạch","lookup:plans",True,None),("AsOf","Đến ngày","date",False,None)]},
   {"key":"history","title":"Lịch sử tính KPI","proc":"usp_KPI_History","description":"Xem các lần tính KPI trước đây của một kế hoạch.","fields":[("PlanId","Kế hoạch","lookup:plans",True,None)]}
  ]
 }
}

def page(request, template, **context):
    user = require_user(request)
    if not user:
        return RedirectResponse("/login", status_code=303)
    return templates.TemplateResponse(request=request, name=template, context={"user": user, "modules": MODULES, **context})


def has_permission(user, code, edit=False):
    if not user: return False
    permissions = user.get("permissions") or {}
    if not isinstance(permissions, dict): return False
    item = permissions.get(code, {})
    return bool(item.get("can_edit" if edit else "can_view", False))

def require_permission(request, code, edit=False):
    user=require_user(request)
    if not user: raise HTTPException(401,"Vui lòng đăng nhập")
    if not has_permission(user,code,edit): raise HTTPException(403,"Bạn không có quyền thực hiện chức năng này.")
    return user

def password_hash(password):
    if len(password)<8 or not any(c.isupper() for c in password) or not any(c.islower() for c in password) or not any(c.isdigit() for c in password):
        raise ValueError("Mật khẩu phải có ít nhất 8 ký tự, gồm chữ hoa, chữ thường và chữ số.")
    salt=secrets.token_bytes(16); digest=hashlib.pbkdf2_hmac("sha256",password.encode(),salt,10000,dklen=32)
    return "PBKDF2$10000$"+base64.b64encode(salt).decode()+"$"+base64.b64encode(digest).decode()

def as_int(value,label):
    try: return int(value) if value not in (None,"") else None
    except (TypeError,ValueError): raise ValueError(f"{label} phải là số nguyên hợp lệ.")

@app.get("/", response_class=HTMLResponse)
def home(request: Request):
    return RedirectResponse("/dashboard", status_code=303) if require_user(request) else RedirectResponse("/login", status_code=303)

@app.get("/login", response_class=HTMLResponse)
def login_page(request: Request):
    return templates.TemplateResponse(request=request, name="login.html", context={"error": None})

@app.post("/login")
def login(request: Request, username: str = Form(...), password: str = Form(...)):
    try:
        result = execute_procedure("usp_User_GetForLogin", {"Username": username.strip()})
        rows = result[0] if result else []
        if not rows:
            execute_procedure("usp_User_LoginResult", {"Username": username.strip(), "Success": False, "Machine": "EVN03-WEB"})
            return templates.TemplateResponse(request=request, name="login.html", context={"error": "Tên đăng nhập hoặc mật khẩu không đúng."}, status_code=401)
        user = rows[0]
        status = str(user.get("Status", ""))
        locked_until = user.get("LockedUntil")
        if locked_until and isinstance(locked_until, str):
            try: locked_until = datetime.fromisoformat(locked_until)
            except ValueError: locked_until = None
        if locked_until and locked_until > datetime.now():
            return templates.TemplateResponse(request=request, name="login.html", context={"error": f"Tài khoản đang bị khóa đến {locked_until:%d/%m/%Y %H:%M}."}, status_code=403)
        if status != "ACTIVE":
            msg = "Tài khoản chưa được kích hoạt." if status == "PENDING" else "Tài khoản hiện không hoạt động hoặc đang bị khóa."
            return templates.TemplateResponse(request=request, name="login.html", context={"error": msg}, status_code=403)
        if not verify_password(password, str(user.get("PasswordHash", ""))):
            execute_procedure("usp_User_LoginResult", {"Username": username.strip(), "Success": False, "Machine": "EVN03-WEB"})
            return templates.TemplateResponse(request=request, name="login.html", context={"error": "Tên đăng nhập hoặc mật khẩu không đúng."}, status_code=401)
        execute_procedure("usp_User_LoginResult", {"Username": username.strip(), "Success": True, "Machine": "EVN03-WEB"})
        uid = user.get("UserId")
        perms = execute_procedure("usp_User_Permissions", {"UserId": uid})
        permission_map = {str(r.get("PermissionCode", "")): {"can_view": bool(r.get("CanView")), "can_edit": bool(r.get("CanEdit"))} for r in (perms[0] if perms else [])}
        request.session["user"] = {"id":uid,"username":username.strip(),"email":user.get("Email"),"name":user.get("FullName") or username.strip(),"role":user.get("RoleName") or "","role_code":user.get("RoleCode") or "","permissions":permission_map}
        return RedirectResponse("/dashboard", status_code=303)
    except Exception as exc:
        return templates.TemplateResponse(request=request, name="login.html", context={"error": f"Không kết nối/đăng nhập được: {exc}"}, status_code=500)

@app.get("/logout")
def logout(request: Request):
    request.session.clear()
    return RedirectResponse("/login", status_code=303)

@app.get("/dashboard", response_class=HTMLResponse)
def dashboard(request: Request):
    user=require_user(request)
    if not user: return RedirectResponse("/login",status_code=303)
    if not has_permission(user,"UC10"): raise HTTPException(403,"Bạn không có quyền xem Dashboard (UC10).")
    return RedirectResponse("/m/dashboard",status_code=303)

@app.get("/m/dashboard", response_class=HTMLResponse)
def dashboard_module(request: Request, building_id: str|None=None, energy_id: str|None=None, date_from: str|None=None, date_to: str|None=None):
    require_permission(request,"UC10")
    now=datetime.now().replace(microsecond=0); error=None
    b_id=None; e_id=None
    display_from=date_from or (now-timedelta(days=7)).date().isoformat(); display_to=date_to or now.date().isoformat()
    try:
        b_id=as_int(building_id,"Tòa nhà")
        e_id=as_int(energy_id,"Loại năng lượng")
        dt_from=datetime.fromisoformat(date_from) if date_from else now-timedelta(days=7)
        dt_to=datetime.fromisoformat(date_to)+timedelta(days=1) if date_to else now+timedelta(seconds=1)
        if dt_to<=dt_from: raise ValueError("Ngày kết thúc phải sau hoặc bằng ngày bắt đầu.")
        br=execute_procedure("usp_Building_List",{"OnlyActive":False}); buildings=br[0] if br else []
        fr=execute_procedure("usp_Floor_List",{}); floors=fr[0] if fr else []
        er=execute_procedure("usp_EnergyType_List",{}); energy_types=er[0] if er else []
        if e_id is None and energy_types: e_id=int(energy_types[0]["EnergyTypeId"])
        if e_id is None: raise ValueError("Chưa có loại năng lượng để hiển thị.")
        q={"BuildingId":b_id,"EnergyTypeId":e_id,"From":dt_from,"To":dt_to}
        sm=execute_procedure("usp_Dash_Summary",q); grain="DAY" if (dt_to-dt_from).total_seconds()>259200 else "HOUR"
        lp=execute_procedure("usp_Dash_LoadProfile",{**q,"Grain":grain}); fl=execute_procedure("usp_Dash_ByFloor",q); hm=execute_procedure("usp_Dash_Heatmap",q)
        ms=execute_procedure("usp_Dash_MeterStatus",{"BuildingId":b_id,"EnergyTypeId":e_id})
        rh=execute_procedure("usp_Report_History",{"Top":100})
        data={"summary":sm[0][0] if sm and sm[0] else None,"load":lp[0] if lp else [],"floors":fl[0] if fl else [],"heat":hm[0] if hm else [],"meters":ms[0] if ms else [],"history":rh[0] if rh else []}
    except Exception as exc:
        error=str(exc); data={"summary":None,"load":[],"floors":[],"heat":[],"meters":[],"history":[]}
        try:
            br=execute_procedure("usp_Building_List",{"OnlyActive":False}); buildings=br[0] if br else []
            fr=execute_procedure("usp_Floor_List",{}); floors=fr[0] if fr else []
            er=execute_procedure("usp_EnergyType_List",{}); energy_types=er[0] if er else []
        except Exception: buildings=[]; floors=[]; energy_types=[]
        dt_from=now-timedelta(days=7); dt_to=now+timedelta(seconds=1)
        display_from=dt_from.date().isoformat(); display_to=now.date().isoformat()
    module=next(m for m in MODULES if m["key"]=="dashboard")
    return page(request,"dashboard_uc10.html",active="dashboard",module=module,data=data,buildings=buildings,floors=locals().get("floors",[]),energy_types=energy_types,
      filters={"building_id":b_id,"energy_id":e_id,"date_from":display_from,"date_to":display_to},grain=locals().get("grain","DAY"),error=error)

@app.get("/m/{key}", response_class=HTMLResponse)
def module_page(request: Request, key: str):
    module=next((m for m in MODULES if m["key"]==key),None)
    if not module: raise HTTPException(404,"Không tìm thấy chức năng")
    user=require_user(request)
    if not user: return RedirectResponse("/login",status_code=303)
    if key=="dashboard": return RedirectResponse("/m/dashboard",status_code=303)
    if key=="users":
        require_permission(request,"UC11")
        try:
            u=execute_procedure("usp_User_List",{"Keyword":None,"RoleId":None}); r=execute_procedure("usp_Role_List",{}); h=execute_procedure("usp_LoginHistory_List",{"Top":300})
            return page(request,"users_uc11.html",active=key,module=module,users=u[0] if u else [],roles=r[0] if r else [],history=h[0] if h else [],error=None)
        except Exception as exc: return page(request,"users_uc11.html",active=key,module=module,users=[],roles=[],history=[],error=str(exc))
    if key=="email":
        try:
            admin=has_permission(user,"UC11",edit=True); rs=execute_procedure("usp_Email_List",{"Status":None,"Top":300,"ToEmail":None if admin else user.get("email")})
            return page(request,"email_uc11.html",active=key,module=module,emails=rs[0] if rs else [],all_mail=admin,error=None)
        except Exception as exc: return page(request,"email_uc11.html",active=key,module=module,emails=[],all_mail=user.get("role_code")=="ADMIN",error=str(exc))
    code=module.get("uc")
    if code and not has_permission(user,code): raise HTTPException(403,f"Bạn không có quyền xem {code}.")
    if key in WORKFLOWS:
        workflow=WORKFLOWS[key]; datasets=[]; lookups={}
        try:
            for ds in workflow["datasets"]:
                rs=execute_procedure(ds["proc"],ds["params"]); datasets.append({**ds,"rows":rs[0] if rs else [],"error":None})
            lookups=build_lookups()
            error=None
        except Exception as exc: error=str(exc)
        return page(request,"workflow.html",active=key,module=module,workflow=workflow,datasets=datasets,lookups=lookups,error=error)
    sections=CRUD_SECTIONS.get(key,[]); section_data=[]; lookups={}
    try:
        for sec in sections:
            rs=execute_procedure(sec["list_proc"],sec.get("list_params",{})); section_data.append({**sec,"rows":rs[0] if rs else [],"error":None})
        lookups=build_lookups()
        error=None
    except Exception as exc: error=str(exc)
    return page(request,"module.html",active=key,module=module,sections=section_data,lookups=lookups,error=error)

@app.get("/activate",response_class=HTMLResponse)
def activate_page(request: Request):
    return templates.TemplateResponse(request=request, name="activate.html", context={"error": None, "message": None})

@app.post("/activate",response_class=HTMLResponse)
def activate_account(request: Request,username:str=Form(...),token:str=Form(...),password:str=Form(...),confirm_password:str=Form(...)):
    try:
        if password!=confirm_password: raise ValueError("Mật khẩu xác nhận không khớp.")
        execute_procedure("usp_User_Activate",{"Username":username.strip(),"Token":token.strip().upper(),"PasswordHash":password_hash(password)})
        return templates.TemplateResponse(request=request, name="activate.html", context={"error": None, "message": "Kích hoạt thành công. Bạn có thể đăng nhập."})
    except Exception as exc:
        return templates.TemplateResponse(request=request, name="activate.html", context={"error": str(exc), "message": None}, status_code=400)

@app.post("/api/users/{action}")
async def user_admin_action(request: Request,action:str):
    user=require_permission(request,"UC11",edit=True)
    try:
        body=await request.json(); v=body.get("values",{})
        if not isinstance(v,dict): raise ValueError("Dữ liệu gửi lên không hợp lệ.")
        if action=="create":
            rs=execute_procedure("usp_User_Create",{"Username":str(v.get("Username") or "").strip(),"Email":str(v.get("Email") or "").strip(),"FullName":str(v.get("FullName") or "").strip(),"RoleId":as_int(v.get("RoleId"),"Vai trò"),"CreatedBy":user.get("id")})
            return {"ok":True,"message":"Đã tạo tài khoản PENDING và đưa thư kích hoạt vào hộp thư.","result_sets":rs}
        if action=="update":
            execute_procedure("usp_User_Update",{"UserId":as_int(v.get("UserId"),"UserId"),"FullName":str(v.get("FullName") or "").strip(),"Email":str(v.get("Email") or "").strip(),"RoleId":as_int(v.get("RoleId"),"Vai trò")})
            return {"ok":True,"message":"Đã cập nhật tài khoản. Quyền mới có hiệu lực sau khi người dùng đăng nhập lại."}
        if action=="status":
            execute_procedure("usp_User_SetStatus",{"UserId":as_int(v.get("UserId"),"UserId"),"Status":str(v.get("Status") or ""),"ActingUserId":user.get("id")})
            return {"ok":True,"message":"Đã cập nhật trạng thái tài khoản."}
        if action=="reset":
            rs=execute_procedure("usp_User_ResetPassword",{"UserId":as_int(v.get("UserId"),"UserId")})
            return {"ok":True,"message":"Đã tạo mã kích hoạt mới và đưa thư vào hộp thư.","result_sets":rs}
        if action=="delete":
            uid=as_int(v.get("UserId"),"UserId")
            if uid==user.get("id"): raise ValueError("Không thể xóa tài khoản đang đăng nhập.")
            execute_procedure("usp_User_Delete",{"UserId":uid}); return {"ok":True,"message":"Đã xóa tài khoản."}
        if action=="permissions":
            rid=as_int(v.get("RoleId"),"Vai trò"); items=v.get("Items")
            if not isinstance(items,list) or len(items)>50: raise ValueError("Danh sách quyền không hợp lệ.")
            for it in items:
                code=str(it.get("PermissionCode") or "")
                if code not in {f"UC{i:02d}" for i in range(1,12)}: raise ValueError("Mã quyền không hợp lệ.")
                view=bool(it.get("CanView")); edit=bool(it.get("CanEdit"))
                execute_procedure("usp_RolePermission_Save",{"RoleId":rid,"PermissionCode":code,"CanView":view or edit,"CanEdit":edit})
            return {"ok":True,"message":"Đã lưu phân quyền. Người dùng cần đăng nhập lại để cập nhật quyền."}
        raise HTTPException(404,"Thao tác không hợp lệ.")
    except HTTPException: raise
    except Exception as exc: return JSONResponse({"ok":False,"error":str(exc)},status_code=400)

@app.get("/api/roles/{role_id}/permissions")
def role_permissions(request: Request,role_id:int):
    require_permission(request,"UC11")
    try:
        rs=execute_procedure("usp_Permission_Matrix",{"RoleId":role_id}); return {"ok":True,"rows":rs[0] if rs else []}
    except Exception as exc: return JSONResponse({"ok":False,"error":str(exc)},status_code=400)

@app.post("/api/reports/export")
async def export_report(request: Request):
    user=require_permission(request,"UC10",edit=False)
    try:
        v=(await request.json()).get("values",{}); building=as_int(v.get("BuildingId"),"Tòa nhà"); floor=as_int(v.get("FloorId"),"Tầng"); energy=as_int(v.get("EnergyTypeId"),"Loại năng lượng")
        if not energy: raise ValueError("Vui lòng chọn loại năng lượng.")
        start=datetime.fromisoformat(v.get("From")); end=datetime.fromisoformat(v.get("To"))+timedelta(days=1)
        if end<=start: raise ValueError("Khoảng thời gian không hợp lệ.")
        grain=str(v.get("Grain") or "DAY").upper(); fmt=str(v.get("Format") or "XLSX").upper()
        if grain not in ("HOUR","DAY","MONTH") or fmt not in ("XLSX","PDF"): raise ValueError("Chu kỳ hoặc định dạng báo cáo không hợp lệ.")
        rs=execute_procedure("usp_Report_Consumption",{"BuildingId":building,"FloorId":floor,"EnergyTypeId":energy,"From":start,"To":end,"Grain":grain}); rows=rs[0] if rs else []
        if not rows: raise ValueError("Không có dữ liệu báo cáo trong khoảng đã chọn. Vui lòng thay đổi bộ lọc.")
        out=Path(__file__).resolve().parent.parent/"exports"; out.mkdir(exist_ok=True); stamp=datetime.now().strftime("%Y%m%d_%H%M%S")
        filename=f"EVN03_Consumption_{stamp}.{fmt.lower()}"; filepath=out/filename; headers=list(rows[0].keys())
        if fmt=="XLSX":
            from openpyxl import Workbook
            from openpyxl.styles import Font,PatternFill
            wb=Workbook(); ws=wb.active; ws.title="Bao cao tieu thu"; ws.append(["BÁO CÁO TIÊU THỤ NĂNG LƯỢNG"]); ws.append([f"Từ {start:%d/%m/%Y} đến {(end-timedelta(days=1)):%d/%m/%Y} · {user.get('name')}"]); ws.append(headers)
            for row in rows: ws.append([row.get(h) for h in headers])
            for c in ws[3]: c.font=Font(bold=True,color="FFFFFF"); c.fill=PatternFill("solid",fgColor="1F4E78")
            ws.freeze_panes="A4"; ws.auto_filter.ref=ws.dimensions
            for col in ws.columns: ws.column_dimensions[col[0].column_letter].width=min(38,max(13,max(len(str(c.value or "")) for c in col)+2))
            wb.save(filepath)
        else:
            from reportlab.lib import colors
            from reportlab.lib.pagesizes import A4,landscape
            from reportlab.platypus import SimpleDocTemplate,Table,TableStyle,Paragraph,Spacer
            from reportlab.lib.styles import getSampleStyleSheet
            from reportlab.pdfbase import pdfmetrics
            from reportlab.pdfbase.ttfonts import TTFont
            from xml.sax.saxutils import escape as xml_escape
            font_candidates=[("C:/Windows/Fonts/arial.ttf","EVNArial"),("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf","EVNDejaVu")]
            font_name="Helvetica"
            for font_path,font_alias in font_candidates:
                if os.path.exists(font_path):
                    try: pdfmetrics.registerFont(TTFont(font_alias,font_path)); font_name=font_alias; break
                    except Exception: pass
            styles=getSampleStyleSheet(); styles["Title"].fontName=font_name; styles["Normal"].fontName=font_name
            data=[[str(x) for x in headers]]+[[str(row.get(h) if row.get(h) is not None else "") for h in headers] for row in rows]
            tbl=Table(data,repeatRows=1); tbl.setStyle(TableStyle([("BACKGROUND",(0,0),(-1,0),colors.HexColor("#1F4E78")),("TEXTCOLOR",(0,0),(-1,0),colors.white),("FONTNAME",(0,0),(-1,-1),font_name),("FONTSIZE",(0,0),(-1,-1),7),("GRID",(0,0),(-1,-1),.25,colors.grey),("ROWBACKGROUNDS",(0,1),(-1,-1),[colors.white,colors.whitesmoke])]))
            story=[Paragraph("BÁO CÁO TIÊU THỤ NĂNG LƯỢNG",styles["Title"]),Paragraph(xml_escape(f"Từ {start:%d/%m/%Y} đến {(end-timedelta(days=1)):%d/%m/%Y} | {user.get('name')}"),styles["Normal"]),Spacer(1,12),tbl]
            SimpleDocTemplate(str(filepath),pagesize=landscape(A4),rightMargin=20,leftMargin=20,topMargin=24,bottomMargin=24).build(story)
        filters=f"BuildingId={building};FloorId={floor};EnergyTypeId={energy};From={start.isoformat()};To={end.isoformat()};Grain={grain}"
        execute_procedure("usp_Report_Log",{"ReportType":"CONSUMPTION","Format":fmt,"Filters":filters[:300],"RecordCount":len(rows),"FilePath":str(filepath)[:300],"UserId":user.get("id")})
        return FileResponse(str(filepath),filename=filename,media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" if fmt=="XLSX" else "application/pdf")
    except Exception as exc: return JSONResponse({"ok":False,"error":str(exc)},status_code=400)

@app.post("/api/modules/{key}/save")
async def save_module_record(request: Request, key: str):
    user = require_user(request)
    if not user:
        raise HTTPException(401, "Vui lòng đăng nhập")
    module = next((m for m in MODULES if m["key"] == key), None)
    if not module or not has_permission(user, module.get("uc", ""), edit=True): raise HTTPException(403, "Bạn không có quyền sửa phân hệ này.")
    sections = CRUD_SECTIONS.get(key)
    if not sections:
        raise HTTPException(404, "Phân hệ chưa có biểu mẫu nhập liệu")
    body = await request.json()
    section_index = body.get("section")
    try:
        section = sections[int(section_index)]
    except (ValueError, TypeError, IndexError):
        raise HTTPException(400, "Nhóm dữ liệu không hợp lệ")
    raw = body.get("values", {})
    if not isinstance(raw, dict):
        raise HTTPException(400, "Dữ liệu biểu mẫu không hợp lệ")
    fields = section["fields"]
    params = {}
    for name, label, kind, required, options in fields:
        value = raw.get(name)
        if value in ("", None):
            if required:
                raise HTTPException(400, f"{label}: vui lòng nhập/chọn dữ liệu")
            value = None
        elif kind == "number":
            try:
                value = float(value) if any(c in str(value) for c in ".eE") else int(value)
            except (ValueError, TypeError):
                raise HTTPException(400, f"{label}: phải là số hợp lệ")
        elif kind == "datetime-local":
            try:
                value = datetime.fromisoformat(str(value))
            except ValueError:
                raise HTTPException(400, f"{label}: thời gian không hợp lệ")
        elif kind == "select" and isinstance(options, list) and name in ("IsActive",):
            value = str(value).lower() in ("true", "1", "yes")
        params[name] = value
    if section["save_proc"] == "usp_Meter_Save":
        params["UserId"] = user.get("id")
    if section["save_proc"] == "usp_Telemetry_ManualEntry":
        params["RecordedBy"] = user.get("id")
    if section["save_proc"] == "usp_Quota_Save":
        params["UserId"] = user.get("id")
    try:
        result = execute_procedure(section["save_proc"], params)
        return {"ok": True, "message": "Đã lưu dữ liệu.", "result_sets": result}
    except Exception as exc:
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)

@app.post("/api/modules/{key}/delete")
async def delete_module_record(request: Request, key: str):
    user = require_user(request)
    if not user:
        raise HTTPException(401, "Vui lòng đăng nhập")
    module = next((m for m in MODULES if m["key"] == key), None)
    if not module or not has_permission(user, module.get("uc", ""), edit=True): raise HTTPException(403, "Bạn không có quyền xóa dữ liệu phân hệ này.")
    sections = CRUD_SECTIONS.get(key, [])
    body = await request.json()
    try:
        section = sections[int(body.get("section"))]
        proc = section.get("delete_proc")
        id_key = section.get("delete_key")
        record_id = int(body.get("id"))
        if not proc or not id_key or proc not in ALLOWED_PROCEDURES:
            raise ValueError("Thao tác xóa không được cấu hình")
        result = execute_procedure(proc, {id_key: record_id})
        return {"ok": True, "message": "Đã xóa bản ghi.", "result_sets": result}
    except Exception as exc:
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)


@app.post("/api/workflows/{key}/{action_key}")
async def run_workflow_action(request: Request, key: str, action_key: str):
    user = require_user(request)
    if not user:
        raise HTTPException(401, "Vui lòng đăng nhập")
    module = next((m for m in MODULES if m["key"] == key), None)
    workflow = WORKFLOWS.get(key)
    action = next((a for a in workflow.get("actions", []) if a["key"] == action_key), None) if workflow else None
    if not module or not action: raise HTTPException(404, "Thao tác không tồn tại")
    read_only = {"usp_Monitor_Status","usp_Alert_List","usp_DQ_List","usp_DQ_ScanRuns_List","usp_CA_List","usp_CA_Series","usp_Transform_PreviewJson","usp_Audit_List","usp_Transform_Methods_List","usp_Plan_List","usp_Solution_List","usp_KPI_Series","usp_KPI_History","usp_KPI_Summary"}
    if not has_permission(user, module.get("uc", ""), edit=action["proc"] not in read_only): raise HTTPException(403, "Bạn không có quyền thực hiện thao tác này.")
    try:
        body = await request.json()
        raw = body.get("values", {})
        if not isinstance(raw, dict):
            raise ValueError("Dữ liệu gửi lên không hợp lệ")
        if key == "transformations":
            if action_key in ("preview", "apply"):
                raw_ids = str(raw.get("RawIds") or "")
                try:
                    ids = sorted(set(int(x.strip()) for x in raw_ids.split(",") if x.strip()))
                except ValueError:
                    raise ValueError("RawId phải là danh sách số nguyên, phân cách bằng dấu phẩy")
                if not ids or any(x <= 0 for x in ids) or len(ids) > 500:
                    raise ValueError("Chọn từ 1 đến 500 RawId hợp lệ")
                method = str(raw.get("MethodCode") or "")
                if method not in {"LINEAR_INTERP", "MOVING_AVG", "NOISE_FILTER", "MEAN_DEFAULT"}:
                    raise ValueError("Phương pháp biến đổi không hợp lệ")
                try: window = int(raw.get("Window") or 2)
                except (ValueError, TypeError): raise ValueError("Window phải là số nguyên")
                if not 1 <= window <= 60: raise ValueError("Window phải trong khoảng 1..60")
                signature = {"ids": ids, "method": method, "window": window}
                if action_key == "preview":
                    request.session.pop("uc07_preview", None)
                    result = execute_procedure("usp_Transform_PreviewJson", {"TargetsJson": json.dumps(ids), "MethodCode": method, "Window": window})
                    request.session["uc07_preview"] = {**signature, "created": datetime.now().timestamp()}
                    rows = result[0] if result else []
                    return {"ok": True, "message": f"Preview hoàn tất: {len(rows)} dòng. Chưa có dữ liệu nào bị thay đổi.", "result_sets": result}
                saved = request.session.get("uc07_preview")
                if not saved or saved.get("ids") != ids or saved.get("method") != method or saved.get("window") != window or datetime.now().timestamp()-float(saved.get("created",0)) > 1200:
                    request.session.pop("uc07_preview", None)
                    raise ValueError("Chưa Preview hoặc dữ liệu đã thay đổi/hết hạn. Hãy chạy Preview lại trước khi Apply (BR06).")
                reason = str(raw.get("Reason") or "").strip()
                if not reason: raise ValueError("Lý do điều chỉnh là bắt buộc")
                request.session.pop("uc07_preview", None)
                result = execute_procedure("usp_Transform_ApplyJson", {"TargetsJson": json.dumps(ids), "MethodCode": method, "Window": window, "Reason": reason, "UserId": user.get("id")})
                return {"ok": True, "message": "Đã áp dụng biến đổi và ghi Audit Log.", "result_sets": result}
            if action_key == "confirm_valid":
                params = {"AnomalyId": int(raw.get("AnomalyId")), "UserId": user.get("id"), "Note": str(raw.get("Note") or "").strip()}
                if not params["Note"]: raise ValueError("Lý do xác nhận là bắt buộc")
                result = execute_procedure("usp_Anomaly_ConfirmValid", params)
                return {"ok": True, "message": "Đã xử lý xác nhận dữ liệu đúng và ghi Audit Log theo quy tắc SQL.", "result_sets": result}
            if action_key == "audit_filter":
                params = {
                    "MeterId": int(raw["MeterId"]) if raw.get("MeterId") else None,
                    "From": datetime.fromisoformat(str(raw["From"])) if raw.get("From") else None,
                    "To": datetime.fromisoformat(str(raw["To"])) if raw.get("To") else None,
                    "UserId": None,
                    "ActionType": raw.get("ActionType") or None,
                    "Top": int(raw.get("Top") or 200)
                }
                result = execute_procedure("usp_Audit_List", params)
                return {"ok": True, "message": "Đã tra cứu Audit Log.", "result_sets": result}
        params = {}
        for name, label, kind, required, options in action["fields"]:
            value = raw.get(name)
            if value in (None, ""):
                if required:
                    raise ValueError(f"{label}: vui lòng nhập/chọn dữ liệu")
                value = None
            elif kind in ("number", "lookup:meters", "lookup:buildings", "lookup:floors", "lookup:rooms", "lookup:energy_types", "lookup:plans"):
                try: value = int(value) if str(value).strip() else None
                except (ValueError, TypeError): raise ValueError(f"{label}: phải là số nguyên hợp lệ")
            elif kind == "decimal":
                try: value = float(value) if str(value).strip() else None
                except (ValueError, TypeError): raise ValueError(f"{label}: phải là số hợp lệ")
            elif kind == "datetime-local":
                try: value = datetime.fromisoformat(str(value)) if str(value).strip() else None
                except ValueError: raise ValueError(f"{label}: thời gian không hợp lệ")
            elif kind == "select" and name in ("Rescan", "Aggregate"):
                value = str(value).lower() in ("true", "1", "yes")
            params[name] = value
        if action["proc"] in ("usp_Alert_SetStatus", "usp_CA_SetStatus", "usp_DQ_Scan", "usp_CA_Scan", "usp_Plan_Save", "usp_KPI_Calculate"):
            params["UserId"] = user.get("id")
        result = execute_procedure(action["proc"], params)
        return {"ok": True, "message": "Thao tác đã thực thi.", "result_sets": result}
    except Exception as exc:
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)

@app.get("/api/health")
def health():
    try:
        return {"ok": True, **test_connection()}
    except Exception as exc:
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=503)

@app.get("/api/procedures")
def procedures(request: Request):
    if not require_user(request):
        raise HTTPException(401, "Vui lòng đăng nhập")
    return {"procedures": sorted(ALLOWED_PROCEDURES)}

@app.post("/api/procedures/{proc_name}")
async def call_procedure(request: Request, proc_name: str):
    if not require_user(request):
        raise HTTPException(401, "Vui lòng đăng nhập")
    if proc_name in {"usp_Transform_PreviewJson", "usp_Transform_ApplyJson"}:
        raise HTTPException(403, "UC07 bắt buộc đi qua quy trình Preview/Apply có kiểm soát; không gọi adapter trực tiếp.")
    if proc_name.startswith(("usp_User_", "usp_RolePermission_", "usp_Permission_", "usp_LoginHistory_", "usp_Email_")):
        raise HTTPException(403, "UC11 phải sử dụng màn hình quản trị; không gọi stored procedure trực tiếp.")
    if proc_name.startswith(("usp_Dash_", "usp_Report_")):
        raise HTTPException(403, "Dashboard và báo cáo phải thao tác qua bộ lọc và chức năng xuất báo cáo UC10.")
    proc_uc = next((m["uc"] for m in MODULES if proc_name in m.get("procs", [])), None)
    read_only_procs = {"usp_Building_List","usp_Floor_List","usp_Room_List","usp_FloorPlan_Get","usp_Meter_List","usp_Meter_Lookup","usp_EnergyType_List","usp_Telemetry_List","usp_Aggregate_List","usp_IngestLog_List","usp_Quota_List","usp_Monitor_Status","usp_Alert_List","usp_DQ_List","usp_DQ_ScanRuns_List","usp_CA_List","usp_CA_Series","usp_Transform_Methods_List","usp_Audit_List","usp_Plan_List","usp_Solution_List","usp_KPI_Series","usp_KPI_History","usp_KPI_Summary"}
    if proc_uc and not has_permission(require_user(request), proc_uc, edit=proc_name not in read_only_procs):
        raise HTTPException(403,"Bạn không có quyền gọi thủ tục này.")
    if proc_name not in ALLOWED_PROCEDURES:
        raise HTTPException(404, "Stored procedure không được cho phép")
    try:
        body = await request.json()
        params = body.get("params", {})
        if not isinstance(params, dict):
            raise ValueError("params phải là một JSON object.")
        result = execute_procedure(proc_name, params)
        return {"ok": True, "result_sets": result}
    except Exception as exc:
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)

@app.get("/api/modules")
def modules(request: Request):
    if not require_user(request):
        raise HTTPException(401, "Vui lòng đăng nhập")
    return {"modules": MODULES}