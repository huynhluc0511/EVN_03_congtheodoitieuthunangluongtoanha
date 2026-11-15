# Phase 4 – UC07 đến UC09

## UC07 – Làm sạch dữ liệu và Audit Log
- Danh sách ứng viên lấy từ `usp_DQ_List` với `Status=OPEN`; chọn RawId theo danh sách.
- Preview gọi adapter `usp_Transform_PreviewJson`, adapter chuyển JSON thành `dbo.IdListType` rồi gọi `usp_Transform_Preview` gốc. Preview không ghi dữ liệu.
- Apply chỉ được máy chủ chấp nhận khi cùng session đã Preview đúng RawId/phương pháp/Window trong tối đa 20 phút; server so khớp lại chữ ký, không chỉ tin giao diện. Apply gọi `usp_Transform_ApplyJson` -> `usp_Transform_Apply` gốc.
- Apply yêu cầu lý do và tự gắn UserId từ session. Transaction, cập nhật RawTelemetry, aggregate và AuditLog do SQL gốc xử lý.
- `usp_Anomaly_ConfirmValid` dùng cho trường hợp dữ liệu bất thường được xác nhận là đúng thực tế; NEGATIVE/MISSING bị SQL từ chối.
- Audit Log tra cứu bằng `usp_Audit_List`; trigger SQL gốc chặn UPDATE/DELETE.

## UC08 – Kế hoạch tiết kiệm
- Tạo/cập nhật kế hoạch qua `usp_Plan_Save`; UserId lấy từ session.
- BR07 được SQL kiểm tra: `0 < TargetPercent <= 100`; số ngày baseline 7..365; phạm vi tầng/phòng phải khớp tòa nhà.
- Quản lý trạng thái, xóa kế hoạch, thêm/sửa/xóa/liệt kê giải pháp qua các stored procedure gốc. Xóa kế hoạch đã có KPI bị FK/SQL từ chối.

## UC09 – KPI
- Tính KPI, chuỗi Baseline/Actual/Target, lịch sử và tổng hợp qua các stored procedure gốc.
- UserId khi tính KPI lấy từ session. Baseline theo ngày thường/cuối tuần; chỉ ngày đủ dữ liệu toàn bộ công tơ được tính theo BR08.
- KPI summary dùng `usp_KPI_Summary` (có gọi refresh trạng thái kế hoạch).

## Cài đặt cập nhật
1. Chạy `Database/UC07_Transform_Audit.sql` sau khi đã chạy các script nền UC01–UC06 và có `dbo.IdListType`. Hoặc dùng `Database/EnergyPortalDB_Full.sql` bản đã bổ sung hai adapter JSON.
2. Các UC08/UC09 dùng script `Database/UC08_SavingPlans.sql` và `Database/UC09_KPI.sql` như bộ SQL gốc.
3. Cập nhật mã web từ ZIP Phase 4, cài `requirements.txt`, cấu hình `.env`, chạy `run.bat`.

## Giới hạn xác minh
Đã kiểm tra cú pháp Python, template, cấu hình allowlist và luồng API bằng mock. Chưa kết nối SQL Server thực tế trong môi trường đóng gói; cần chạy các script trên SQL Server của bạn để xác minh dữ liệu, quyền và tương thích phiên bản SQL Server. Adapter dùng `OPENJSON` (SQL Server 2016+).
