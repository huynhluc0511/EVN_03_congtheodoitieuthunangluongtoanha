# EVN-03 Web — dự án VS Code + FastAPI + SQL Server

## 1. Phạm vi phiên bản hiện tại

Dự án web này được dựng từ hai tài liệu người dùng cung cấp:
- `GiuakiEVN3.docx`: mô tả 11 Use Case, 67 use case con, luồng nghiệp vụ và BR01–BR08.
- `EnergyPortalDB_Full.sql`: script SQL Server, stored procedure và ứng dụng WinForms tham chiếu.


Giao diện khởi tạo có đăng nhập, bố cục sidebar tương tự ứng dụng WinForms, trang tổng quan và 13 mục điều hướng bao phủ UC01–UC11. Mỗi phân hệ đã có truy vấn dữ liệu ban đầu và bộ gọi stored procedure theo allowlist.

 Đã có biểu mẫu web cho tòa nhà, tầng/mặt bằng chữ nhật, phòng, công tơ, nhập chỉ số thủ công và định mức. Các màn hình hỗ trợ thêm/cập nhật; danh sách dữ liệu; xóa đối với tòa nhà/tầng/phòng/công tơ/định mức (SQL Server sẽ từ chối nếu còn dữ liệu liên quan). Form gọi stored procedure tương ứng, không tự viết lại quy tắc nghiệp vụ.

 Bổ sung UC10 Dashboard/Báo cáo và UC11 Tài khoản/Phân quyền. Dự án hiện có giao diện nghiệp vụ UC01–UC11, 

## 2. Công nghệ

- Python + FastAPI + Jinja2
- SQL Server 2017+ (theo script gốc)
- `pyodbc` + Microsoft ODBC Driver 18 for SQL Server
- HTML/CSS/JavaScript; không cần Node.js để chạy bản khởi tạo

## 3. Yêu cầu máy Windows

1. Python 3.11 trở lên 
2. SQL Server 2017+ và SQL Server Management Studio (SSMS).
3. Microsoft ODBC Driver 18 for SQL Server.
4. VS Code.

## 4. Tạo CSDL

1. Mở SSMS và kết nối đúng SQL Server instance.
2. Mở `Database/EnergyPortalDB_Full.sql`.
3. Chạy toàn bộ script (Execute).


Tài khoản demo theo README của ZIP: `admin`, `quanly`, `ktv`, `banql`; mật khẩu chung `Admin@123`. Đây là thông tin demo từ bộ WinForms; nếu seed đã thay đổi hoặc đăng nhập không được, kiểm tra `99_SeedData.sql` và bảng Users. Đổi mật khẩu trước khi triển khai thật.

## 5. Cấu hình kết nối SQL Server

1. Copy `.env.example` thành `.env`.
2. Mở `.env`, sửa `DB_SERVER`:
   - SQL Server mặc định: `localhost`
   - SQL Express: `localhost\\SQLEXPRESS`
   - LocalDB: `(localdb)\\MSSQLLocalDB`
3. Nếu dùng Windows Authentication: để `DB_TRUSTED_CONNECTION=yes`.
4. Nếu dùng SQL Login: đặt `DB_TRUSTED_CONNECTION=no`, điền `DB_USERNAME` và `DB_PASSWORD`.
5. Đổi `SESSION_SECRET` thành chuỗi bí mật dài, riêng tư.

Ví dụ SQL Express:
```env
DB_SERVER=localhost\\SQLEXPRESS
DB_NAME=EnergyPortalDB
DB_TRUSTED_CONNECTION=yes
```

## 6. Chạy trong VS Code / Terminal (PowerShell)

Mở thư mục `EVN03_Web_VSCode` trong VS Code, mở Terminal:

```powershell
py -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
Copy-Item .env.example .env
```

Sửa `.env`, sau đó chạy:

```powershell
python -m uvicorn app.main:app --reload
```

Mở trình duyệt: http://127.0.0.1:8000

Có thể chạy nhanh bằng cách nhấp đúp `run.bat` (cần cấu hình `.env` trước).

Nếu PowerShell chặn activate:
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\.venv\Scripts\Activate.ps1
```

## 7. Kiểm tra kết nối

- Trạng thái: `http://127.0.0.1:8000/api/health`
- Danh sách thủ tục được cho phép: đăng nhập rồi mở `http://127.0.0.1:8000/api/procedures`
- Mỗi phân hệ có trang `/m/<key>`.


## 8. Trạng thái triển khai nghiệp vụ (cập nhật)

| Nhóm | Phân hệ web cần hoàn thiện |
|---|---|
| UC01 | Đã có form tòa nhà, tầng, phòng, công tơ; lưu/xóa gọi stored procedure; BR01/BR02 được SQL kiểm tra. GIS hiện nhập tọa độ X/Y trong mặt bằng chữ nhật, chưa có bản đồ tương tác. |
| UC02 | Đã có form ghi nhận chỉ số thủ công; batch IoT/TVP, tổng hợp, log và metrics còn cần làm. |
| UC03 | Đã có form thêm/cập nhật/xóa định mức; BR04 do stored procedure kiểm tra giá trị > 0 và khung thời gian trùng. |
| UC04 | Đã có trang giám sát trạng thái, quét ngay, lọc cảnh báo, tiếp nhận/đóng cảnh báo; email được SQL xếp hàng cho ENERGY_MANAGER. |
| UC05 | Đã có trang quét chất lượng, lọc NEGATIVE/MISSING/SPIKE/NO_SIGNAL và lịch sử quét; SQL xếp email cho TECHNICIAN. Chưa có procedure cập nhật trạng thái lỗi trong SQL nguồn. |
| UC06 | Đã có tính Baseline, quét/lọc bất thường, cập nhật trạng thái và tra cứu chuỗi thực tế/Baseline/ngưỡng/tuần trước. |
| UC07 | Có danh sách bất thường, Preview/Apply có kiểm tra server-side cùng lựa chọn trong 20 phút, xác nhận dữ liệu đúng và tra cứu Audit Log bất biến. Cần chạy lại script UC07 để cài JSON adapter. |
| UC08 | Có tạo/cập nhật/lọc kế hoạch, đổi trạng thái, xóa theo điều kiện SQL và quản lý giải pháp. BR07 do SQL kiểm tra. |
| UC09 | Có tính KPI, biểu đồ chuỗi thực tế/Baseline/mục tiêu, lịch sử và tổng hợp. BR08 do SQL kiểm tra. |
| UC10 | Dashboard có bộ lọc tòa nhà/năng lượng/thời gian; KPI tổng quan; phụ tải giờ/ngày; tiêu thụ theo tầng; heatmap tầng × giờ; trạng thái công tơ; xuất XLSX/PDF; lịch sử ReportExports. |
| UC11 | Đăng nhập, khóa đăng nhập theo số lần sai, kích hoạt PBKDF2; tạo/cập nhật/khóa/mở khóa/đặt lại/xóa tài khoản; ma trận RolePermissions; lịch sử đăng nhập; EmailOutbox (người có CanEdit UC11 xem toàn bộ; người dùng khác chỉ xem email của mình). |

## 9. Các quy tắc nghiệp vụ không được bỏ qua

- BR01: mã công tơ duy nhất.
- BR02: công tơ gắn không gian và tọa độ GIS nằm trong ranh giới mặt bằng.
- BR03: timestamp dữ liệu hợp lệ.
- BR04: định mức > 0 và không chồng lấn thời gian trong cùng khu vực.
- BR05: tách Data Anomaly (lỗi kỹ thuật dữ liệu) khỏi Consumption Anomaly (bất thường vận hành).
- BR06: làm sạch phải Preview trước khi Apply; Audit Log lưu vết bất biến.
- BR07: mục tiêu tiết kiệm lớn hơn 0% và không vượt 100% (đối chiếu chi tiết mô tả trong Word).
- BR08: chỉ dữ liệu đã kiểm tra chất lượng hoặc làm sạch mới được dùng cho baseline, KPI và báo cáo.

## 10. Cấu trúc thư mục

```text
EVN03_Web_VSCode/
├── app/
│   ├── main.py
│   ├── database.py
│   ├── procedure_catalog.py
│   ├── security.py
│   ├── templates/
│   └── static/
├── Database/                 
├── docs/  
├── .env.example
├── requirements.txt
├── run.bat
└── README.md
```


## 11. Tài liệu các giai đoạn

- `docs/UC01_UC03.md`: biểu mẫu UC01–UC03.
- `docs/UC04_UC06.md`: quy trình giám sát và phát hiện bất thường UC04–UC06.


##  – UC07 đến UC09
Đã bổ sung UC07 Preview/Apply + Audit Log, UC08 kế hoạch/giải pháp tiết kiệm và UC09 KPI. Xem `docs/UC07_UC09.md` để biết thứ tự chạy SQL 

##  UC07 đến UC09
Xem `docs/PHASE4_UC07_UC09.md` để biết chức năng, thứ tự cài SQL và giới hạn kiểm thử. UC07 dùng adapter JSON -> `IdListType` để gọi stored procedure TVP gốc, không thay đổi transaction/Audit Log gốc.

##  UC10 đến UC11
Xem `docs/UC10_UC11.md` để biết chức năng, bảo mật, xuất báo cáo, thứ tự chạy SQL và giới hạn kiểm thử. UC10/UC11 dùng các stored procedure trong SQL gốc; không yêu cầu thay đổi schema khi đã cài `EnergyPortalDB_Full.sql`.
