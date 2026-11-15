# Phase 5 – UC10 Dashboard/Báo cáo và UC11 Tài khoản/Phân quyền

## UC10 – Dashboard & Reports

Trang: `/m/dashboard`

- Bộ lọc tòa nhà, loại năng lượng, ngày bắt đầu/kết thúc.
- KPI: tổng tiêu thụ, chi phí ước tính, công tơ hoạt động, cảnh báo đỏ/vàng, mất tín hiệu, bất thường dữ liệu/tiêu thụ, kế hoạch đang chạy.
- Biểu đồ phụ tải theo giờ khi khoảng lọc ngắn, theo ngày khi khoảng lọc dài; các bucket chưa đầy đủ được tô cảnh báo.
- Tiêu thụ theo tầng.
- Heatmap tầng × giờ; `usp_Dash_Heatmap` lọc `IsComplete=1` như SQL gốc.
- Trạng thái công tơ GREEN/YELLOW/RED/GREY theo SQL gốc.
- Xuất Excel `.xlsx` và PDF từ `usp_Report_Consumption`; lưu lịch sử qua `usp_Report_Log`; hiển thị 100 lần gần nhất qua `usp_Report_History`.
- Không có dữ liệu thì báo người dùng thay đổi bộ lọc, không tạo tệp rỗng.

**Lưu ý BR08 quan trọng:** giữ nguyên SQL nguồn. `usp_Dash_Summary` và `usp_Dash_LoadProfile` hiện không lọc `IsComplete=1`; LoadProfile trả `AllComplete` để UI đánh dấu bucket chưa đầy đủ. `usp_Dash_Heatmap` lọc `IsComplete=1`. `usp_Report_Consumption` lọc `ValidCount>0` nhưng không có điều kiện `IsComplete=1`. Nếu yêu cầu nghiệm thu BR08 diễn giải là chỉ được dùng bucket hoàn chỉnh/đã làm sạch, cần thống nhất và sửa SQL procedure có chủ đích; web không tự ý thay đổi logic gốc.

## UC11 – Tài khoản và phân quyền

Trang: `/m/users` (cần quyền UC11), `/m/email` (hộp thư của người dùng đã đăng nhập).

- Login dùng `usp_User_GetForLogin`, `usp_User_LoginResult`, `usp_User_Permissions`.
- Lưu `RoleCode` và map `PermissionCode -> CanView/CanEdit` vào session.
- Kiểm tra quyền xem/sửa ở server cho trang phân hệ, CRUD API và workflow API. Các thao tác chỉ đọc được phép với CanView; thao tác ghi yêu cầu CanEdit.
- ADMIN có quyền quản trị theo role code; các vai trò khác theo `RolePermissions`.
- Tạo tài khoản qua `usp_User_Create`: SQL kiểm tra trùng username/email, tạo PENDING và đưa thư kích hoạt vào `EmailOutbox`.
- `/activate`: đặt mật khẩu và kích hoạt qua `usp_User_Activate`. Hash PBKDF2-HMAC-SHA256, 10.000 vòng, salt 16 byte, 32-byte key; tương thích định dạng C# gốc.
- Cập nhật, khóa/mở khóa, reset mật khẩu, xóa đều gọi stored procedure gốc. SQL giữ quy tắc không khóa/hạ quyền admin cuối cùng và không xóa user đã có dữ liệu liên quan.
- Ma trận quyền lưu qua `usp_RolePermission_Save`; quyền sửa kéo theo quyền xem; admin không thể tự thu hồi UC11.
- Lịch sử đăng nhập qua `usp_LoginHistory_List`.
- EmailOutbox: người có CanEdit UC11 xem tất cả (mặc định ADMIN); người dùng khác chỉ xem thư gửi đến email của chính họ. Web chưa có SMTP sender, vì vậy trạng thái SENT/FAILED chỉ phản ánh dữ liệu trong outbox, không có nút giả lập gửi thành công.

## Cài đặt / cập nhật

- Database mới: chạy `Database/EnergyPortalDB_Full.sql` một lần. File gộp đã gồm các script UC11, UC01–UC10 và phần seed demo ở cuối; không chạy lặp nếu không muốn nạp lại dữ liệu mẫu.
- Database hiện tại đã cài UC01–UC11: không cần migration mới cho UC10–UC11; xác nhận `UC10_Dashboard_Reports.sql` và `UC11_Accounts.sql` đã được chạy trong database. Nếu chưa, chạy theo thứ tự: `00_Common.sql`, các script UC01–UC09 cần thiết, `UC10_Dashboard_Reports.sql`, `UC11_Accounts.sql`, rồi `99_SeedData.sql` (chỉ khi muốn dữ liệu mẫu).
- Cài Python packages: `python -m pip install -r requirements.txt` (Phase 5 thêm `openpyxl` và `reportlab`).
- Đăng nhập demo theo `99_SeedData.sql`: `admin`, `quanly`, `ktv`, `banql`; mật khẩu `Admin@123`. Đổi mật khẩu demo trước khi dùng thật.
- Tài khoản tạo mới sẽ ở PENDING; mở `/m/email` bằng ADMIN để xem mã kích hoạt trong thư outbox rồi mở `/activate` để kích hoạt trong môi trường demo. Không coi đó là luồng gửi email production.

## Kiểm thử đã thực hiện

- `py_compile` các module Python.
- Jinja2 compile và render smoke test cho dashboard UC10, users UC11, email UC11.
- Import FastAPI với stub `pyodbc`, xác nhận route UC10/UC11.
- TestClient mock: đăng nhập admin, render dashboard, render quản trị user, render EmailOutbox, gọi API tạo tài khoản.
- TestClient mock xuất XLSX: tạo file, trả response download và gọi `usp_Report_Log`.
- Kiểm tra password seed `Admin@123` tương thích PBKDF2.
- `node --check` cho JavaScript.

**Chưa thực hiện:** kết nối SQL Server thật, kiểm thử stored procedure trên DB người dùng, gửi SMTP thật, test đầy đủ vai trò và 67 use case con. Cần chạy thực tế trước nghiệm thu.
