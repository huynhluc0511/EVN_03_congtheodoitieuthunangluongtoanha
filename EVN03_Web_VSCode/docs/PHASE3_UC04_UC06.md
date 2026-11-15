# Phase 3 — UC04, UC05, UC06

## Phạm vi triển khai

### UC04 — Giám sát và cảnh báo vượt định mức

- Hiển thị trạng thái theo định mức từ `usp_Monitor_Status` (GREEN/YELLOW/RED/NODATA).
- Chạy quét ngay qua `usp_Monitor_Scan`, mặc định nhìn lại 3 ngày.
- Hiển thị danh sách cảnh báo qua `usp_Alert_List`, hỗ trợ lọc trạng thái/mức độ.
- Cập nhật cảnh báo qua `usp_Alert_SetStatus`; `UserId` lấy từ phiên đăng nhập.
- Khi đóng cảnh báo (`RESOLVED`), stored procedure yêu cầu ghi chú biện pháp xử lý.
- Logic tính toán, chống tạo trùng cảnh báo, nâng mức VÀNG → ĐỎ và xếp email cho ENERGY_MANAGER nằm trong SQL nguồn.

### UC05 — Phân tích và phát hiện bất thường dữ liệu

- Chạy `usp_DQ_Scan` theo công tơ/khoảng thời gian hoặc quét các dữ liệu PENDING khi bỏ trống khoảng thời gian.
- Cho phép chọn chế độ MANUAL/SCHEDULED, quét lại dữ liệu VALID và tổng hợp lại sau quét.
- Hiển thị danh sách qua `usp_DQ_List`, lọc theo trạng thái/công tơ/loại lỗi.
- Hiển thị lịch sử chạy qua `usp_DQ_ScanRuns_List`.
- Các loại lỗi theo SQL nguồn: NEGATIVE, MISSING, SPIKE, NO_SIGNAL; mã lỗi DQ-001 đến DQ-004.
- Email thông báo được xếp cho vai trò TECHNICIAN bởi stored procedure khi phát hiện bất thường.
- SQL nguồn hiện không định nghĩa stored procedure cập nhật trạng thái DataAnomalies; giao diện không tự ý cập nhật trực tiếp bảng.

### UC06 — Phân tích và cảnh báo bất thường tiêu thụ

- Tính Baseline qua `usp_Baseline_Compute`.
- Quét bất thường qua `usp_CA_Scan`; truyền UserId phiên đăng nhập.
- Hiển thị danh sách qua `usp_CA_List`, lọc theo trạng thái/công tơ.
- Cập nhật trạng thái qua `usp_CA_SetStatus`; khi chọn PLANNED bắt buộc ghi chú hoạt động có kế hoạch.
- Tra cứu chuỗi qua `usp_CA_Series`: thực tế, Baseline, ngưỡng trên, kỳ tuần trước và cờ bất thường.
- SQL nguồn chỉ dùng dữ liệu tổng hợp `IsComplete=1` cho Baseline và phát hiện; dữ liệu chưa đạt chất lượng được bỏ qua.
- Phân loại theo SQL nguồn: OFF_HOURS, OVERLOAD, LEAK; mức LOW/MEDIUM/HIGH.

## Quy tắc quan trọng

- BR05: Data Anomaly và Consumption Anomaly được lưu ở hai nhóm bảng riêng, không gộp chung.
- BR08: UC06 chỉ phân tích dữ liệu đã đạt chất lượng (`IsComplete=1`).
- UC04 so sánh thực tế với định mức, cảnh báo VÀNG khi đạt ngưỡng cảnh báo và ĐỎ khi đạt/vượt 100%.
- UC05 là lỗi kỹ thuật đầu vào: âm, khuyết, nhảy vọt, mất tín hiệu.
- UC06 là bất thường vận hành: ngoài giờ, quá tải, rò rỉ.

## Kiểm tra đã thực hiện trong gói

- `python -m py_compile` cho các module Python.
- Nạp/compile các template Jinja2.
- Import ứng dụng với stub `pyodbc` để kiểm tra khai báo route và cấu hình workflow.
- Đối chiếu tên procedure và tham số hiển thị với các file `Database/UC04_Monitoring.sql`, `UC05_DataAnomaly.sql`, `UC06_ConsumptionAnomaly.sql`.

## Chưa xác nhận

Chưa có SQL Server chạy kèm trong môi trường đóng gói, do đó chưa xác nhận kết nối ODBC, quyền EXECUTE, kết quả stored procedure, gửi email thực tế hoặc dữ liệu mẫu. Các trang phụ thuộc schema/seed SQL gốc và cần chạy tích hợp trên máy người dùng.
