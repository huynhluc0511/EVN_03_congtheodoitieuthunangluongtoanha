# Phase 2 — UC01 đến UC03

## Đã triển khai

- UC01: biểu mẫu tòa nhà (`usp_Building_Save/List/Delete`), tầng (`usp_Floor_Save/List/Delete`), phòng (`usp_Room_Save/List/Delete`) và công tơ (`usp_Meter_Save/List/Delete`).
- UC01 BR01: mã công tơ duy nhất được kiểm tra trong `usp_Meter_Save`.
- UC01 BR02: công tơ phải thuộc tầng/phòng hợp lệ; tọa độ X/Y phải nằm trong đa giác mặt bằng. UI hiện nhập tọa độ và dùng vùng chữ nhật do procedure tạo.
- UC02: nhập chỉ số thủ công qua `usp_Telemetry_ManualEntry`; thủ tục căn timestamp theo chu kỳ công tơ và thực hiện các kiểm tra BR03/không trùng mốc, ghi log tiếp nhận.
- UC03: thêm/cập nhật/xóa định mức và tra cứu qua `usp_Quota_*`; procedure kiểm tra giá trị dương, chu kỳ, ngày/giờ hợp lệ và chồng lấn.
- Dropdown liên kết dữ liệu cho tòa nhà, tầng, phòng, loại năng lượng và công tơ.
- Thông báo thành công/lỗi trả về từ API; thao tác xóa có xác nhận ở trình duyệt.

## Kiểm tra đã thực hiện

- Python `compileall` cho mã ứng dụng.
- Jinja2 parse toàn bộ template.
- Render thử template UC01 và xác nhận nút xóa gửi đúng chỉ số section/ID.
- Đối chiếu tên stored procedure trong cấu hình form với các script SQL đi kèm.

## Chưa thể xác nhận trong môi trường tạo mã

- Chưa kết nối được SQL Server thật để chạy end-to-end; môi trường tạo gói không có `pyodbc`/SQL Server.
- Chưa kiểm thử đăng nhập, quyền SQL, dữ liệu seed, thao tác lưu/xóa với từng database instance.
- Mặt bằng mới là vùng chữ nhật theo MinX/MinY/MaxX/MaxY; chưa phải trình biên tập polygon/GIS trực quan.
- Form cập nhật nhận ID do người dùng nhập; chưa có thao tác bấm dòng để tự nạp dữ liệu vào form.

## Chạy thử

Thực hiện theo README.md. Sau khi đăng nhập, mở:

- `/m/spaces` — tòa nhà, tầng, phòng.
- `/m/meters` — công tơ.
- `/m/readings` — nhập chỉ số thủ công.
- `/m/quotas` — định mức.

Nếu stored procedure trả lỗi ràng buộc, kiểm tra thông báo ở ngay dưới form; không bỏ qua lỗi bằng cách sửa trực tiếp dữ liệu trong bảng.
