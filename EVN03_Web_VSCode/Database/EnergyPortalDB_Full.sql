/* =====================================================================
   CỔNG THEO DÕI TIÊU THỤ NĂNG LƯỢNG TÒA NHÀ (EVN-03)
   00_Common.sql - Tạo CSDL + các thành phần dùng chung
   Yêu cầu: SQL Server 2017 trở lên (dùng STRING_AGG, CREATE OR ALTER,
            kiểu không gian geometry thay cho PostGIS)
   Thứ tự chạy: 00 -> UC11 -> UC01 -> UC02 -> ... -> UC10 -> 99_SeedData
   ===================================================================== */
USE master;
GO
IF DB_ID(N'EnergyPortalDB') IS NULL
    CREATE DATABASE EnergyPortalDB;   -- dùng collation mặc định của server để khớp với tempdb (tránh lỗi collation conflict với bảng tạm)
GO
USE EnergyPortalDB;
GO

/* ---------- Tham số hệ thống ---------- */
IF OBJECT_ID(N'dbo.SystemSettings', N'U') IS NULL
CREATE TABLE dbo.SystemSettings(
    SettingKey   VARCHAR(50)    NOT NULL CONSTRAINT PK_SystemSettings PRIMARY KEY,
    SettingValue NVARCHAR(100)  NOT NULL,
    Description  NVARCHAR(200)  NULL
);
GO
MERGE dbo.SystemSettings AS t
USING (VALUES
 ('WORK_START_HOUR',     N'7',   N'Giờ bắt đầu làm việc (dùng phân loại bất thường ngoài giờ)'),
 ('WORK_END_HOUR',       N'18',  N'Giờ kết thúc làm việc (không bao gồm)'),
 ('ANOMALY_Z',           N'3',   N'Hệ số độ lệch chuẩn để xác định bất thường tiêu thụ (UC06)'),
 ('ANOMALY_MIN_RATIO',   N'1.2', N'Tiêu thụ phải vượt đường cơ sở tối thiểu bao nhiêu lần (UC06)'),
 ('SPIKE_FACTOR',        N'8',   N'Nhảy vọt khi giá trị > hệ số x trung bình 24 chu kỳ trước (UC05)'),
 ('NO_SIGNAL_HOURS',     N'6',   N'Số giờ không có dữ liệu thì coi là mất tín hiệu (UC05)'),
 ('BASELINE_DAYS',       N'28',  N'Số ngày dùng tính đường cơ sở (Baseline)'),
 ('KPI_BEHIND_THRESHOLD',N'80',  N'Dưới ngưỡng % so với mục tiêu thì coi là tiến độ chậm (UC09)'),
 ('FUTURE_TOLERANCE_MIN',N'5',   N'Cho phép lệch giờ (phút) với timestamp tương lai (UC02)'),
 ('LOGIN_MAX_FAILED',    N'5',   N'Số lần đăng nhập sai tối đa trước khi khóa tạm (UC11)'),
 ('LOGIN_LOCK_MINUTES',  N'15',  N'Số phút khóa tạm tài khoản (UC11)'),
 ('ACTIVATION_HOURS',    N'48',  N'Hiệu lực mã kích hoạt tài khoản (giờ) (UC11)')
) AS s(k,v,d) ON t.SettingKey=s.k
WHEN NOT MATCHED THEN INSERT(SettingKey,SettingValue,Description) VALUES(s.k,s.v,s.d);
GO

CREATE OR ALTER FUNCTION dbo.fn_SettingNum(@Key VARCHAR(50))
RETURNS DECIMAL(18,4) AS
BEGIN
    RETURN (SELECT TRY_CAST(SettingValue AS DECIMAL(18,4)) FROM dbo.SystemSettings WHERE SettingKey=@Key);
END
GO

/* Loại ngày: 1900-01-01 là thứ Hai nên phần dư >=5 là Thứ 7/CN (không phụ thuộc @@DATEFIRST) */
CREATE OR ALTER FUNCTION dbo.fn_DayType(@d DATE)
RETURNS VARCHAR(7) AS
BEGIN
    RETURN CASE WHEN DATEDIFF(DAY,'19000101',@d) % 7 >= 5 THEN 'WEEKEND' ELSE 'WEEKDAY' END;
END
GO

/* ---------- Hộp thư gửi đi (Dịch vụ email tự động) ---------- */
IF OBJECT_ID(N'dbo.EmailOutbox', N'U') IS NULL
CREATE TABLE dbo.EmailOutbox(
    EmailId      BIGINT IDENTITY(1,1) CONSTRAINT PK_EmailOutbox PRIMARY KEY,
    ToEmail      NVARCHAR(150) NOT NULL,
    ToName       NVARCHAR(100) NULL,
    Subject      NVARCHAR(200) NOT NULL,
    Body         NVARCHAR(MAX) NOT NULL,
    EmailType    VARCHAR(20)   NOT NULL,          -- ACTIVATION / QUOTA_ALERT / DATA_ANOMALY / CONSUMPTION / OTHER
    Status       VARCHAR(10)   NOT NULL CONSTRAINT DF_EmailOutbox_Status DEFAULT 'PENDING',
    CreatedAt    DATETIME2(0)  NOT NULL CONSTRAINT DF_EmailOutbox_Created DEFAULT SYSDATETIME(),
    SentAt       DATETIME2(0)  NULL,
    Attempts     INT           NOT NULL CONSTRAINT DF_EmailOutbox_Attempts DEFAULT 0,
    ErrorMessage NVARCHAR(500) NULL,
    CONSTRAINT CK_EmailOutbox_Status CHECK (Status IN ('PENDING','SENT','FAILED'))
);
GO

/* ---------- Metric hệ thống (mô phỏng OpenTelemetry) ---------- */
IF OBJECT_ID(N'dbo.SystemMetrics', N'U') IS NULL
CREATE TABLE dbo.SystemMetrics(
    MetricId    BIGINT IDENTITY(1,1) CONSTRAINT PK_SystemMetrics PRIMARY KEY,
    MetricName  VARCHAR(80)    NOT NULL,
    MetricValue DECIMAL(18,3)  NOT NULL,
    Unit        VARCHAR(20)    NULL,
    Labels      NVARCHAR(200)  NULL,
    RecordedAt  DATETIME2(0)   NOT NULL CONSTRAINT DF_SystemMetrics_At DEFAULT SYSDATETIME()
);
GO
CREATE OR ALTER PROCEDURE dbo.usp_Metric_Emit
    @Name VARCHAR(80), @Value DECIMAL(18,3), @Unit VARCHAR(20)=NULL, @Labels NVARCHAR(200)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.SystemMetrics(MetricName,MetricValue,Unit,Labels) VALUES(@Name,@Value,@Unit,@Labels);
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Metric_List @Top INT = 500
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Top) MetricId, MetricName, MetricValue, Unit, Labels, RecordedAt
    FROM dbo.SystemMetrics ORDER BY MetricId DESC;
END
GO

/* ---------- Kiểu bảng dùng làm tham số (TVP) ---------- */
IF TYPE_ID(N'dbo.IdListType') IS NULL
    CREATE TYPE dbo.IdListType AS TABLE(Id BIGINT NOT NULL PRIMARY KEY);
GO
IF TYPE_ID(N'dbo.TelemetryBatchType') IS NULL
    CREATE TYPE dbo.TelemetryBatchType AS TABLE(
        MeterCode    VARCHAR(30)   NULL,
        ReadingTime  DATETIME2(0)  NULL,
        ReadingValue DECIMAL(18,3) NULL);
GO
/* =====================================================================
   UC11 - QUẢN LÝ TÀI KHOẢN VÀ PHÂN QUYỀN
   Phân rã:
     11.1 Đăng nhập & ghi lịch sử            -> usp_User_GetForLogin, usp_User_LoginResult
     11.2 Tạo tài khoản mới                  -> usp_User_Create   (TRANSACTION: user + email)
     11.3 Kiểm tra trùng Email/Tên đăng nhập -> trong usp_User_Create / usp_User_Update
     11.4 Mã hóa mật khẩu                    -> thực hiện ở tầng ứng dụng (PBKDF2), DB chỉ lưu hash
     11.5 Gửi email kích hoạt                -> EmailOutbox (include)
     11.6 Kích hoạt tài khoản                -> usp_User_Activate
     11.7 Phân quyền vai trò/chức năng       -> Roles, Permissions, RolePermissions
     11.8 Khóa / mở khóa / đặt lại mật khẩu  -> usp_User_SetStatus, usp_User_ResetPassword
     11.9 Xóa tài khoản chưa phát sinh dữ liệu -> usp_User_Delete (FK chặn)
   ===================================================================== */
USE EnergyPortalDB;
GO

IF OBJECT_ID(N'dbo.Roles', N'U') IS NULL
CREATE TABLE dbo.Roles(
    RoleId      INT           NOT NULL CONSTRAINT PK_Roles PRIMARY KEY,
    RoleCode    VARCHAR(30)   NOT NULL CONSTRAINT UQ_Roles_Code UNIQUE,
    RoleName    NVARCHAR(100) NOT NULL,
    Description NVARCHAR(200) NULL
);
GO
IF OBJECT_ID(N'dbo.Permissions', N'U') IS NULL
CREATE TABLE dbo.Permissions(
    PermissionCode VARCHAR(10)   NOT NULL CONSTRAINT PK_Permissions PRIMARY KEY,
    PermissionName NVARCHAR(150) NOT NULL
);
GO
IF OBJECT_ID(N'dbo.RolePermissions', N'U') IS NULL
CREATE TABLE dbo.RolePermissions(
    RoleId         INT         NOT NULL CONSTRAINT FK_RolePerm_Role REFERENCES dbo.Roles(RoleId),
    PermissionCode VARCHAR(10) NOT NULL CONSTRAINT FK_RolePerm_Perm REFERENCES dbo.Permissions(PermissionCode),
    CanView        BIT         NOT NULL CONSTRAINT DF_RolePerm_View DEFAULT 1,
    CanEdit        BIT         NOT NULL CONSTRAINT DF_RolePerm_Edit DEFAULT 0,
    CONSTRAINT PK_RolePermissions PRIMARY KEY(RoleId,PermissionCode),
    CONSTRAINT CK_RolePerm CHECK (CanEdit=0 OR CanView=1)
);
GO
IF OBJECT_ID(N'dbo.Users', N'U') IS NULL
CREATE TABLE dbo.Users(
    UserId           INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Users PRIMARY KEY,
    Username         NVARCHAR(50)  NOT NULL CONSTRAINT UQ_Users_Username UNIQUE,
    Email            NVARCHAR(150) NOT NULL CONSTRAINT UQ_Users_Email UNIQUE,
    FullName         NVARCHAR(100) NOT NULL,
    PasswordHash     NVARCHAR(300) NULL,                 -- PBKDF2$iter$salt$hash (không bao giờ lưu mật khẩu thô)
    RoleId           INT           NOT NULL CONSTRAINT FK_Users_Role REFERENCES dbo.Roles(RoleId),
    Status           VARCHAR(10)   NOT NULL CONSTRAINT DF_Users_Status DEFAULT 'PENDING',
    ActivationToken  VARCHAR(20)   NULL,
    ActivationExpiry DATETIME2(0)  NULL,
    FailedLoginCount INT           NOT NULL CONSTRAINT DF_Users_Failed DEFAULT 0,
    LockedUntil      DATETIME2(0)  NULL,
    CreatedAt        DATETIME2(0)  NOT NULL CONSTRAINT DF_Users_Created DEFAULT SYSDATETIME(),
    CreatedBy        INT           NULL CONSTRAINT FK_Users_CreatedBy REFERENCES dbo.Users(UserId),
    LastLoginAt      DATETIME2(0)  NULL,
    CONSTRAINT CK_Users_Status CHECK (Status IN ('PENDING','ACTIVE','LOCKED','DISABLED')),
    CONSTRAINT CK_Users_Hash   CHECK (Status='PENDING' OR PasswordHash IS NOT NULL),
    CONSTRAINT CK_Users_Email  CHECK (Email LIKE '%_@_%._%')
);
GO
IF OBJECT_ID(N'dbo.LoginHistory', N'U') IS NULL
CREATE TABLE dbo.LoginHistory(
    LoginId     BIGINT IDENTITY(1,1) CONSTRAINT PK_LoginHistory PRIMARY KEY,
    UserId      INT           NULL CONSTRAINT FK_LoginHistory_User REFERENCES dbo.Users(UserId),
    Username    NVARCHAR(50)  NOT NULL,
    LoginTime   DATETIME2(0)  NOT NULL CONSTRAINT DF_LoginHistory_Time DEFAULT SYSDATETIME(),
    IsSuccess   BIT           NOT NULL,
    MachineName NVARCHAR(100) NULL
);
GO

/* ---------- Dữ liệu danh mục ---------- */
MERGE dbo.Roles AS t USING (VALUES
 (1,'ADMIN',          N'Quản trị viên hệ thống', N'Khai báo công tơ, không gian, tài khoản & phân quyền'),
 (2,'ENERGY_MANAGER', N'Quản lý năng lượng tòa nhà', N'Định mức, cảnh báo, kế hoạch tiết kiệm'),
 (3,'TECHNICIAN',     N'Kỹ thuật viên vận hành', N'Thu thập thủ công, xử lý bất thường, biến đổi dữ liệu'),
 (4,'BUILDING_BOARD', N'Ban quản lý tòa nhà', N'Xem KPI và dashboard')
) s(id,c,n,d) ON t.RoleId=s.id
WHEN NOT MATCHED THEN INSERT(RoleId,RoleCode,RoleName,Description) VALUES(s.id,s.c,s.n,s.d);

MERGE dbo.Permissions AS t USING (VALUES
 ('UC01',N'Quản lý công tơ & không gian tòa nhà'),
 ('UC02',N'Thu thập & tổng hợp dữ liệu tiêu thụ'),
 ('UC03',N'Thiết lập định mức tiêu thụ'),
 ('UC04',N'Giám sát & cảnh báo vượt định mức'),
 ('UC05',N'Phát hiện bất thường dữ liệu'),
 ('UC06',N'Phân tích bất thường tiêu thụ'),
 ('UC07',N'Biến đổi dữ liệu & Audit Log'),
 ('UC08',N'Lập kế hoạch tiết kiệm năng lượng'),
 ('UC09',N'Theo dõi & đánh giá KPI tiết kiệm'),
 ('UC10',N'Dashboard & xuất báo cáo'),
 ('UC11',N'Quản lý tài khoản & phân quyền')
) s(c,n) ON t.PermissionCode=s.c
WHEN NOT MATCHED THEN INSERT(PermissionCode,PermissionName) VALUES(s.c,s.n);

MERGE dbo.RolePermissions AS t USING (VALUES
 (1,'UC01',1,1),(1,'UC11',1,1),(1,'UC10',1,0),
 (2,'UC03',1,1),(2,'UC04',1,1),(2,'UC06',1,1),(2,'UC08',1,1),(2,'UC09',1,1),(2,'UC10',1,1),
 (3,'UC02',1,1),(3,'UC05',1,1),(3,'UC06',1,1),(3,'UC07',1,1),(3,'UC10',1,1),
 (4,'UC09',1,0),(4,'UC10',1,0)
) s(r,p,v,e) ON t.RoleId=s.r AND t.PermissionCode=s.p
WHEN NOT MATCHED THEN INSERT(RoleId,PermissionCode,CanView,CanEdit) VALUES(s.r,s.p,s.v,s.e);
GO

/* ---------- Hàng đợi email theo vai trò (dùng chung các UC) ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_Email_Queue
    @ToEmail NVARCHAR(150), @ToName NVARCHAR(100)=NULL, @Subject NVARCHAR(200), @Body NVARCHAR(MAX), @Type VARCHAR(20)='OTHER'
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.EmailOutbox(ToEmail,ToName,Subject,Body,EmailType) VALUES(@ToEmail,@ToName,@Subject,@Body,@Type);
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Email_QueueForRole
    @RoleCode VARCHAR(30), @Subject NVARCHAR(200), @Body NVARCHAR(MAX), @Type VARCHAR(20)='OTHER'
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.EmailOutbox(ToEmail,ToName,Subject,Body,EmailType)
    SELECT u.Email,u.FullName,@Subject,@Body,@Type
    FROM dbo.Users u JOIN dbo.Roles r ON r.RoleId=u.RoleId
    WHERE r.RoleCode=@RoleCode AND u.Status='ACTIVE';
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Email_List @Status VARCHAR(10)=NULL, @Top INT=300, @ToEmail NVARCHAR(150)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Top) EmailId,ToEmail,ToName,Subject,Body,EmailType,Status,CreatedAt,SentAt,Attempts,ErrorMessage
    FROM dbo.EmailOutbox WHERE (@Status IS NULL OR Status=@Status) AND (@ToEmail IS NULL OR ToEmail=@ToEmail) ORDER BY EmailId DESC;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Email_MarkResult @EmailId BIGINT, @Success BIT, @Error NVARCHAR(500)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.EmailOutbox
       SET Status=CASE WHEN @Success=1 THEN 'SENT' ELSE 'FAILED' END,
           SentAt=CASE WHEN @Success=1 THEN SYSDATETIME() END,
           Attempts=Attempts+1, ErrorMessage=@Error
     WHERE EmailId=@EmailId;
END
GO

/* ---------- 11.1 Đăng nhập ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_User_GetForLogin @Username NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.UserId,u.Username,u.FullName,u.Email,u.PasswordHash,u.Status,u.LockedUntil,u.FailedLoginCount,
           r.RoleId,r.RoleCode,r.RoleName
    FROM dbo.Users u JOIN dbo.Roles r ON r.RoleId=u.RoleId WHERE u.Username=@Username;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_User_LoginResult
    @Username NVARCHAR(50), @Success BIT, @Machine NVARCHAR(100)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @uid INT=(SELECT UserId FROM dbo.Users WHERE Username=@Username);
    DECLARE @max INT=CAST(dbo.fn_SettingNum('LOGIN_MAX_FAILED') AS INT);
    DECLARE @lock INT=CAST(dbo.fn_SettingNum('LOGIN_LOCK_MINUTES') AS INT);
    IF @uid IS NOT NULL
    BEGIN
        IF @Success=1
            UPDATE dbo.Users SET FailedLoginCount=0,LockedUntil=NULL,LastLoginAt=SYSDATETIME() WHERE UserId=@uid;
        ELSE
            UPDATE dbo.Users SET
                   LockedUntil=CASE WHEN FailedLoginCount+1>=@max THEN DATEADD(MINUTE,@lock,SYSDATETIME()) ELSE LockedUntil END,
                   FailedLoginCount=CASE WHEN FailedLoginCount+1>=@max THEN 0 ELSE FailedLoginCount+1 END
             WHERE UserId=@uid;
    END
    INSERT dbo.LoginHistory(UserId,Username,IsSuccess,MachineName) VALUES(@uid,@Username,@Success,@Machine);
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_User_Permissions @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT rp.PermissionCode,rp.CanView,rp.CanEdit
    FROM dbo.Users u JOIN dbo.RolePermissions rp ON rp.RoleId=u.RoleId WHERE u.UserId=@UserId;
END
GO

/* ---------- 11.2/11.3/11.5 Tạo tài khoản (TRANSACTION) ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_User_Create
    @Username NVARCHAR(50), @Email NVARCHAR(150), @FullName NVARCHAR(100), @RoleId INT, @CreatedBy INT=NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @own BIT=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
    BEGIN TRY
        SET @Username=LTRIM(RTRIM(@Username)); SET @Email=LTRIM(RTRIM(@Email)); SET @FullName=LTRIM(RTRIM(@FullName));
        IF ISNULL(@Username,N'')=N'' OR ISNULL(@Email,N'')=N'' OR ISNULL(@FullName,N'')=N''
            THROW 50201,N'Họ tên, Email và Tên đăng nhập là bắt buộc',1;
        IF @Email NOT LIKE '%_@_%._%' THROW 50202,N'Email không đúng định dạng',1;
        IF EXISTS(SELECT 1 FROM dbo.Users WHERE Username=@Username OR Email=@Email)
            THROW 50203,N'Tên đăng nhập hoặc Email đã tồn tại',1;
        IF NOT EXISTS(SELECT 1 FROM dbo.Roles WHERE RoleId=@RoleId) THROW 50204,N'Vai trò không hợp lệ',1;

        DECLARE @token VARCHAR(20)=UPPER(LEFT(REPLACE(CAST(NEWID() AS VARCHAR(36)),'-',''),10));
        DECLARE @exp DATETIME2(0)=DATEADD(HOUR,CAST(dbo.fn_SettingNum('ACTIVATION_HOURS') AS INT),SYSDATETIME());
        IF @own=1 BEGIN TRAN;
        INSERT dbo.Users(Username,Email,FullName,RoleId,Status,ActivationToken,ActivationExpiry,CreatedBy)
        VALUES(@Username,@Email,@FullName,@RoleId,'PENDING',@token,@exp,@CreatedBy);
        DECLARE @uid INT=SCOPE_IDENTITY();

        DECLARE @body NVARCHAR(MAX)=N'Xin chào '+@FullName+N','+CHAR(13)+CHAR(10)+
            N'Tài khoản của bạn trên Cổng theo dõi tiêu thụ năng lượng đã được tạo.'+CHAR(13)+CHAR(10)+
            N'Tên đăng nhập: '+@Username+CHAR(13)+CHAR(10)+
            N'Mã kích hoạt: '+@token+N' (hiệu lực đến '+CONVERT(NVARCHAR(20),@exp,120)+N').'+CHAR(13)+CHAR(10)+
            N'Mở chức năng "Kích hoạt tài khoản" trên màn hình đăng nhập để đặt mật khẩu.';
        EXEC dbo.usp_Email_Queue @Email,@FullName,N'[EVN-03] Kích hoạt tài khoản',@body,'ACTIVATION';
        IF @own=1 COMMIT;
        SELECT @uid AS UserId,@token AS ActivationToken;
    END TRY
    BEGIN CATCH
        IF @own=1 AND @@TRANCOUNT>0 ROLLBACK;
        THROW;
    END CATCH
END
GO

/* ---------- 11.6 Kích hoạt ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_User_Activate @Username NVARCHAR(50), @Token VARCHAR(20), @PasswordHash NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @uid INT,@st VARCHAR(10),@tk VARCHAR(20),@ex DATETIME2(0);
    SELECT @uid=UserId,@st=Status,@tk=ActivationToken,@ex=ActivationExpiry FROM dbo.Users WHERE Username=@Username;
    IF @uid IS NULL OR @st<>'PENDING' OR @tk IS NULL OR @tk<>UPPER(@Token)
        THROW 50210,N'Tên đăng nhập hoặc mã kích hoạt không đúng',1;
    IF @ex<SYSDATETIME() THROW 50211,N'Mã kích hoạt đã hết hạn, hãy nhờ Quản trị viên cấp lại',1;
    UPDATE dbo.Users SET PasswordHash=@PasswordHash,Status='ACTIVE',ActivationToken=NULL,ActivationExpiry=NULL,
           FailedLoginCount=0,LockedUntil=NULL WHERE UserId=@uid;
END
GO

/* ---------- Cập nhật / trạng thái / đặt lại / xóa ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_User_Update @UserId INT, @FullName NVARCHAR(100), @Email NVARCHAR(150), @RoleId INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF NOT EXISTS(SELECT 1 FROM dbo.Users WHERE UserId=@UserId) THROW 50220,N'Tài khoản không tồn tại',1;
    IF ISNULL(@FullName,N'')=N'' OR ISNULL(@Email,N'')=N'' THROW 50201,N'Họ tên và Email là bắt buộc',1;
    IF @Email NOT LIKE '%_@_%._%' THROW 50202,N'Email không đúng định dạng',1;
    IF EXISTS(SELECT 1 FROM dbo.Users WHERE Email=@Email AND UserId<>@UserId) THROW 50203,N'Tên đăng nhập hoặc Email đã tồn tại',1;
    IF EXISTS(SELECT 1 FROM dbo.Users WHERE UserId=@UserId AND RoleId=1 AND Status='ACTIVE') AND @RoleId<>1
       AND NOT EXISTS(SELECT 1 FROM dbo.Users WHERE RoleId=1 AND Status='ACTIVE' AND UserId<>@UserId)
        THROW 50221,N'Không thể hạ quyền Quản trị viên cuối cùng của hệ thống',1;
    UPDATE dbo.Users SET FullName=@FullName,Email=@Email,RoleId=@RoleId WHERE UserId=@UserId;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_User_SetStatus @UserId INT, @Status VARCHAR(10), @ActingUserId INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF @Status NOT IN ('ACTIVE','LOCKED','DISABLED') THROW 50222,N'Trạng thái không hợp lệ',1;
    IF @UserId=@ActingUserId AND @Status<>'ACTIVE' THROW 50223,N'Không thể khóa chính tài khoản đang đăng nhập',1;
    IF EXISTS(SELECT 1 FROM dbo.Users WHERE UserId=@UserId AND Status='PENDING') THROW 50224,N'Tài khoản chưa kích hoạt',1;
    IF @Status<>'ACTIVE' AND EXISTS(SELECT 1 FROM dbo.Users WHERE UserId=@UserId AND RoleId=1)
       AND NOT EXISTS(SELECT 1 FROM dbo.Users WHERE RoleId=1 AND Status='ACTIVE' AND UserId<>@UserId)
        THROW 50221,N'Không thể khóa Quản trị viên cuối cùng của hệ thống',1;
    UPDATE dbo.Users SET Status=@Status,FailedLoginCount=0,LockedUntil=NULL WHERE UserId=@UserId;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_User_ResetPassword @UserId INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @own BIT=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
    BEGIN TRY
        DECLARE @email NVARCHAR(150),@name NVARCHAR(100),@un NVARCHAR(50);
        SELECT @email=Email,@name=FullName,@un=Username FROM dbo.Users WHERE UserId=@UserId;
        IF @email IS NULL THROW 50220,N'Tài khoản không tồn tại',1;
        DECLARE @token VARCHAR(20)=UPPER(LEFT(REPLACE(CAST(NEWID() AS VARCHAR(36)),'-',''),10));
        DECLARE @exp DATETIME2(0)=DATEADD(HOUR,CAST(dbo.fn_SettingNum('ACTIVATION_HOURS') AS INT),SYSDATETIME());
        IF @own=1 BEGIN TRAN;
        UPDATE dbo.Users SET Status='PENDING',PasswordHash=NULL,ActivationToken=@token,ActivationExpiry=@exp WHERE UserId=@UserId;
        DECLARE @body NVARCHAR(MAX)=N'Xin chào '+@name+N', mật khẩu của bạn đã được đặt lại. Tên đăng nhập: '+@un+
            N'. Mã kích hoạt mới: '+@token+N' (hiệu lực đến '+CONVERT(NVARCHAR(20),@exp,120)+N').';
        EXEC dbo.usp_Email_Queue @email,@name,N'[EVN-03] Đặt lại mật khẩu',@body,'ACTIVATION';
        IF @own=1 COMMIT;
        SELECT @token AS ActivationToken;
    END TRY
    BEGIN CATCH
        IF @own=1 AND @@TRANCOUNT>0 ROLLBACK; THROW;
    END CATCH
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_User_Delete @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DELETE dbo.Users WHERE UserId=@UserId;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()=547 THROW 50225,N'Tài khoản đã phát sinh dữ liệu, chỉ có thể khóa chứ không thể xóa',1;
        THROW;
    END CATCH
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_User_List @Keyword NVARCHAR(100)=NULL, @RoleId INT=NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.UserId,u.Username,u.FullName,u.Email,r.RoleId,r.RoleName,u.Status,u.LastLoginAt,u.CreatedAt,u.ActivationToken
    FROM dbo.Users u JOIN dbo.Roles r ON r.RoleId=u.RoleId
    WHERE (@RoleId IS NULL OR u.RoleId=@RoleId)
      AND (@Keyword IS NULL OR u.Username LIKE N'%'+@Keyword+N'%' OR u.FullName LIKE N'%'+@Keyword+N'%' OR u.Email LIKE N'%'+@Keyword+N'%')
    ORDER BY u.UserId;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Role_List AS BEGIN SET NOCOUNT ON; SELECT RoleId,RoleCode,RoleName FROM dbo.Roles ORDER BY RoleId; END
GO

/* ---------- 11.7 Phân quyền ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_Permission_Matrix @RoleId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT p.PermissionCode,p.PermissionName,CAST(ISNULL(rp.CanView,0) AS BIT) AS CanView,CAST(ISNULL(rp.CanEdit,0) AS BIT) AS CanEdit
    FROM dbo.Permissions p LEFT JOIN dbo.RolePermissions rp ON rp.PermissionCode=p.PermissionCode AND rp.RoleId=@RoleId
    ORDER BY p.PermissionCode;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_RolePermission_Save @RoleId INT, @PermissionCode VARCHAR(10), @CanView BIT, @CanEdit BIT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF @RoleId=1 AND @PermissionCode='UC11' AND (@CanView=0 OR @CanEdit=0)
        THROW 50230,N'Không được thu hồi quyền quản lý tài khoản của vai trò Quản trị viên',1;
    IF @CanEdit=1 SET @CanView=1;
    IF @CanView=0
        DELETE dbo.RolePermissions WHERE RoleId=@RoleId AND PermissionCode=@PermissionCode;
    ELSE IF EXISTS(SELECT 1 FROM dbo.RolePermissions WHERE RoleId=@RoleId AND PermissionCode=@PermissionCode)
        UPDATE dbo.RolePermissions SET CanView=@CanView,CanEdit=@CanEdit WHERE RoleId=@RoleId AND PermissionCode=@PermissionCode;
    ELSE
        INSERT dbo.RolePermissions(RoleId,PermissionCode,CanView,CanEdit) VALUES(@RoleId,@PermissionCode,@CanView,@CanEdit);
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_LoginHistory_List @Top INT=200
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Top) LoginId,Username,LoginTime,IsSuccess,MachineName FROM dbo.LoginHistory ORDER BY LoginId DESC;
END
GO
/* =====================================================================
   UC01 - QUẢN LÝ THÔNG TIN CÔNG TƠ VÀ KHÔNG GIAN TÒA NHÀ
   Phân rã:
     01.1 Quản lý tòa nhà / tầng / phòng (mặt bằng GIS)  -> usp_Building_*, usp_Floor_*, usp_Room_*
     01.2 Khai báo / cập nhật công tơ                    -> usp_Meter_Save
     01.3 Kiểm tra trùng mã công tơ (BR01) «include»      -> UQ_Meters_Code + kiểm tra trong proc
     01.4 Xác thực tọa độ GIS nằm trong mặt bằng (BR02) «include» -> fn_IsPointInside (STContains)
     01.5 Ngưng hoạt động / xóa công tơ                   -> usp_Meter_SetStatus, usp_Meter_Delete
     01.6 Xem sơ đồ mặt bằng định vị công tơ              -> usp_FloorPlan_Get
   Tọa độ GIS: hệ tọa độ phẳng cục bộ của mặt bằng (mét, SRID 0).
   ===================================================================== */
USE EnergyPortalDB;
GO

IF OBJECT_ID(N'dbo.EnergyTypes', N'U') IS NULL
CREATE TABLE dbo.EnergyTypes(
    EnergyTypeId INT           NOT NULL CONSTRAINT PK_EnergyTypes PRIMARY KEY,
    Code         VARCHAR(10)   NOT NULL CONSTRAINT UQ_EnergyTypes_Code UNIQUE,
    Name         NVARCHAR(50)  NOT NULL,
    Unit         NVARCHAR(10)  NOT NULL,
    PricePerUnit DECIMAL(18,2) NOT NULL CONSTRAINT DF_EnergyTypes_Price DEFAULT 0,
    CONSTRAINT CK_EnergyTypes_Price CHECK (PricePerUnit>=0)
);
GO
MERGE dbo.EnergyTypes t USING (VALUES
  (1,'ELEC',N'Điện',N'kWh',2500),(2,'WATER',N'Nước',N'm3',15000),(3,'GAS',N'Gas',N'm3',28000)
) s(i,c,n,u,p) ON t.EnergyTypeId=s.i
WHEN NOT MATCHED THEN INSERT(EnergyTypeId,Code,Name,Unit,PricePerUnit) VALUES(s.i,s.c,s.n,s.u,s.p);
GO

IF OBJECT_ID(N'dbo.Buildings', N'U') IS NULL
CREATE TABLE dbo.Buildings(
    BuildingId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Buildings PRIMARY KEY,
    BuildingCode VARCHAR(20)   NOT NULL CONSTRAINT UQ_Buildings_Code UNIQUE,
    BuildingName NVARCHAR(100) NOT NULL,
    Address      NVARCHAR(200) NULL,
    IsActive     BIT           NOT NULL CONSTRAINT DF_Buildings_Active DEFAULT 1,
    CreatedAt    DATETIME2(0)  NOT NULL CONSTRAINT DF_Buildings_Created DEFAULT SYSDATETIME()
);
GO
IF OBJECT_ID(N'dbo.Floors', N'U') IS NULL
CREATE TABLE dbo.Floors(
    FloorId    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Floors PRIMARY KEY,
    BuildingId INT           NOT NULL CONSTRAINT FK_Floors_Building REFERENCES dbo.Buildings(BuildingId),
    FloorNo    INT           NOT NULL,
    FloorName  NVARCHAR(50)  NOT NULL,
    MinX DECIMAL(10,2) NOT NULL, MinY DECIMAL(10,2) NOT NULL,
    MaxX DECIMAL(10,2) NOT NULL, MaxY DECIMAL(10,2) NOT NULL,
    Boundary   geometry      NOT NULL,                      -- đa giác mặt bằng tầng
    CONSTRAINT UQ_Floors UNIQUE(BuildingId,FloorNo),
    CONSTRAINT CK_Floors_Box CHECK (MaxX>MinX AND MaxY>MinY)
);
GO
IF OBJECT_ID(N'dbo.Rooms', N'U') IS NULL
CREATE TABLE dbo.Rooms(
    RoomId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Rooms PRIMARY KEY,
    FloorId  INT           NOT NULL CONSTRAINT FK_Rooms_Floor REFERENCES dbo.Floors(FloorId),
    RoomCode VARCHAR(20)   NOT NULL CONSTRAINT UQ_Rooms_Code UNIQUE,
    RoomName NVARCHAR(100) NOT NULL,
    MinX DECIMAL(10,2) NOT NULL, MinY DECIMAL(10,2) NOT NULL,
    MaxX DECIMAL(10,2) NOT NULL, MaxY DECIMAL(10,2) NOT NULL,
    Boundary geometry      NOT NULL,
    AreaM2   DECIMAL(12,2) NOT NULL,
    CONSTRAINT CK_Rooms_Box CHECK (MaxX>MinX AND MaxY>MinY)
);
GO
IF OBJECT_ID(N'dbo.Meters', N'U') IS NULL
CREATE TABLE dbo.Meters(
    MeterId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Meters PRIMARY KEY,
    MeterCode     VARCHAR(30)   NOT NULL CONSTRAINT UQ_Meters_Code UNIQUE,            -- BR01
    MeterName     NVARCHAR(100) NOT NULL,
    EnergyTypeId  INT           NOT NULL CONSTRAINT FK_Meters_Energy REFERENCES dbo.EnergyTypes(EnergyTypeId),
    Manufacturer  NVARCHAR(100) NULL,
    Model         NVARCHAR(100) NULL,
    SerialNo      NVARCHAR(50)  NULL,
    Specification NVARCHAR(300) NULL,                                                 -- thông số kỹ thuật
    MaxValuePerInterval DECIMAL(18,3) NULL,                                           -- công suất tối đa/chu kỳ (kiểm tra nhảy vọt)
    IntervalMinutes INT         NOT NULL CONSTRAINT DF_Meters_Interval DEFAULT 60,
    FloorId       INT           NOT NULL CONSTRAINT FK_Meters_Floor REFERENCES dbo.Floors(FloorId),  -- BR02
    RoomId        INT           NULL     CONSTRAINT FK_Meters_Room  REFERENCES dbo.Rooms(RoomId),
    LocX DECIMAL(10,2) NOT NULL, LocY DECIMAL(10,2) NOT NULL,
    Location      geometry      NOT NULL,
    InstallDate   DATE          NULL,
    Status        VARCHAR(10)   NOT NULL CONSTRAINT DF_Meters_Status DEFAULT 'ACTIVE',
    LastReadingAt DATETIME2(0)  NULL,
    CreatedBy     INT           NULL CONSTRAINT FK_Meters_CreatedBy REFERENCES dbo.Users(UserId),
    CreatedAt     DATETIME2(0)  NOT NULL CONSTRAINT DF_Meters_Created DEFAULT SYSDATETIME(),
    UpdatedAt     DATETIME2(0)  NULL,
    CONSTRAINT CK_Meters_Status   CHECK (Status IN ('ACTIVE','INACTIVE','FAULTY')),
    CONSTRAINT CK_Meters_Interval CHECK (IntervalMinutes IN (15,30,60)),
    CONSTRAINT CK_Meters_Max      CHECK (MaxValuePerInterval IS NULL OR MaxValuePerInterval>0)
);
GO
CREATE INDEX IX_Meters_Floor ON dbo.Meters(FloorId) INCLUDE(EnergyTypeId,RoomId,Status);
GO

/* ---------- 01.4 Xác thực tọa độ GIS ---------- */
CREATE OR ALTER FUNCTION dbo.fn_IsPointInside(@FloorId INT,@RoomId INT,@X DECIMAL(10,2),@Y DECIMAL(10,2))
RETURNS BIT AS
BEGIN
    DECLARE @pt geometry=geometry::Point(@X,@Y,0);
    RETURN ISNULL((SELECT CASE WHEN f.Boundary.STContains(@pt)=1
                 AND (@RoomId IS NULL OR EXISTS(SELECT 1 FROM dbo.Rooms r WHERE r.RoomId=@RoomId AND r.FloorId=f.FloorId AND r.Boundary.STContains(@pt)=1))
                 THEN 1 ELSE 0 END
              FROM dbo.Floors f WHERE f.FloorId=@FloorId),0);
END
GO
/* Công tơ thuộc phạm vi (tòa nhà / tầng / phòng) - dùng cho định mức, kế hoạch, KPI; bỏ qua công tơ ngưng hoạt động */
CREATE OR ALTER FUNCTION dbo.fn_MetersInScope(@BuildingId INT,@FloorId INT,@RoomId INT,@EnergyTypeId INT)
RETURNS TABLE AS RETURN
SELECT m.MeterId
FROM dbo.Meters m JOIN dbo.Floors f ON f.FloorId=m.FloorId
WHERE m.EnergyTypeId=@EnergyTypeId AND m.Status<>'INACTIVE'
  AND ( (@RoomId IS NOT NULL AND m.RoomId=@RoomId)
     OR (@RoomId IS NULL AND @FloorId IS NOT NULL AND m.FloorId=@FloorId)
     OR (@RoomId IS NULL AND @FloorId IS NULL AND f.BuildingId=@BuildingId) );
GO
CREATE OR ALTER FUNCTION dbo.fn_PolygonWkt(@MinX DECIMAL(10,2),@MinY DECIMAL(10,2),@MaxX DECIMAL(10,2),@MaxY DECIMAL(10,2))
RETURNS VARCHAR(300) AS
BEGIN
    DECLARE @a VARCHAR(20)=CAST(@MinX AS VARCHAR(20)),@b VARCHAR(20)=CAST(@MinY AS VARCHAR(20)),
            @c VARCHAR(20)=CAST(@MaxX AS VARCHAR(20)),@d VARCHAR(20)=CAST(@MaxY AS VARCHAR(20));
    RETURN 'POLYGON(('+@a+' '+@b+','+@c+' '+@b+','+@c+' '+@d+','+@a+' '+@d+','+@a+' '+@b+'))';
END
GO

/* ---------- 01.1 Tòa nhà ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_Building_Save
    @BuildingId INT=NULL,@BuildingCode VARCHAR(20),@BuildingName NVARCHAR(100),@Address NVARCHAR(200)=NULL,@IsActive BIT=1
AS
BEGIN
    SET NOCOUNT ON;
    SET @BuildingCode=UPPER(LTRIM(RTRIM(@BuildingCode)));
    IF ISNULL(@BuildingCode,'')='' OR ISNULL(@BuildingName,N'')=N'' THROW 50101,N'Mã và tên tòa nhà là bắt buộc',1;
    IF EXISTS(SELECT 1 FROM dbo.Buildings WHERE BuildingCode=@BuildingCode AND BuildingId<>ISNULL(@BuildingId,0))
        THROW 50102,N'Mã tòa nhà đã tồn tại',1;
    IF @BuildingId IS NULL
    BEGIN
        INSERT dbo.Buildings(BuildingCode,BuildingName,Address,IsActive) VALUES(@BuildingCode,@BuildingName,@Address,@IsActive);
        SELECT SCOPE_IDENTITY() AS BuildingId;
    END
    ELSE
    BEGIN   -- khóa mã khi sửa: không đổi BuildingCode
        UPDATE dbo.Buildings SET BuildingName=@BuildingName,Address=@Address,IsActive=@IsActive WHERE BuildingId=@BuildingId;
        SELECT @BuildingId AS BuildingId;
    END
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Building_List @OnlyActive BIT=0
AS BEGIN SET NOCOUNT ON;
    SELECT BuildingId,BuildingCode,BuildingName,Address,IsActive FROM dbo.Buildings WHERE @OnlyActive=0 OR IsActive=1 ORDER BY BuildingCode; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Building_Delete @BuildingId INT
AS BEGIN SET NOCOUNT ON;
    BEGIN TRY DELETE dbo.Buildings WHERE BuildingId=@BuildingId; END TRY
    BEGIN CATCH IF ERROR_NUMBER()=547 THROW 50103,N'Tòa nhà đã có tầng/công tơ/dữ liệu liên quan, không thể xóa',1; THROW; END CATCH
END
GO

/* ---------- 01.1 Tầng ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_Floor_Save
    @FloorId INT=NULL,@BuildingId INT,@FloorNo INT,@FloorName NVARCHAR(50),
    @MinX DECIMAL(10,2),@MinY DECIMAL(10,2),@MaxX DECIMAL(10,2),@MaxY DECIMAL(10,2)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF @MaxX<=@MinX OR @MaxY<=@MinY THROW 50110,N'Ranh giới mặt bằng không hợp lệ (Max phải lớn hơn Min)',1;
    IF ISNULL(@FloorName,N'')=N'' THROW 50111,N'Tên tầng là bắt buộc',1;
    IF NOT EXISTS(SELECT 1 FROM dbo.Buildings WHERE BuildingId=@BuildingId) THROW 50112,N'Tòa nhà không tồn tại',1;
    IF EXISTS(SELECT 1 FROM dbo.Floors WHERE BuildingId=@BuildingId AND FloorNo=@FloorNo AND FloorId<>ISNULL(@FloorId,0))
        THROW 50113,N'Tầng này đã tồn tại trong tòa nhà',1;
    DECLARE @g geometry=geometry::STGeomFromText(dbo.fn_PolygonWkt(@MinX,@MinY,@MaxX,@MaxY),0);
    IF @FloorId IS NOT NULL
    BEGIN   -- mặt bằng mới phải còn chứa mọi phòng và công tơ hiện có
        IF EXISTS(SELECT 1 FROM dbo.Rooms r WHERE r.FloorId=@FloorId AND @g.STContains(r.Boundary)=0)
            THROW 50114,N'Ranh giới mới không còn bao phủ hết các phòng của tầng',1;
        IF EXISTS(SELECT 1 FROM dbo.Meters m WHERE m.FloorId=@FloorId AND @g.STContains(m.Location)=0)
            THROW 50115,N'Ranh giới mới làm một số công tơ nằm ngoài mặt bằng',1;
        UPDATE dbo.Floors SET FloorNo=@FloorNo,FloorName=@FloorName,MinX=@MinX,MinY=@MinY,MaxX=@MaxX,MaxY=@MaxY,Boundary=@g WHERE FloorId=@FloorId;
        SELECT @FloorId AS FloorId;
    END
    ELSE
    BEGIN
        INSERT dbo.Floors(BuildingId,FloorNo,FloorName,MinX,MinY,MaxX,MaxY,Boundary) VALUES(@BuildingId,@FloorNo,@FloorName,@MinX,@MinY,@MaxX,@MaxY,@g);
        SELECT SCOPE_IDENTITY() AS FloorId;
    END
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Floor_List @BuildingId INT=NULL
AS BEGIN SET NOCOUNT ON;
    SELECT f.FloorId,f.BuildingId,b.BuildingName,f.FloorNo,f.FloorName,f.MinX,f.MinY,f.MaxX,f.MaxY,
           CAST(f.Boundary.STArea() AS DECIMAL(12,2)) AS AreaM2
    FROM dbo.Floors f JOIN dbo.Buildings b ON b.BuildingId=f.BuildingId
    WHERE @BuildingId IS NULL OR f.BuildingId=@BuildingId ORDER BY b.BuildingCode,f.FloorNo; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Floor_Delete @FloorId INT
AS BEGIN SET NOCOUNT ON;
    BEGIN TRY DELETE dbo.Floors WHERE FloorId=@FloorId; END TRY
    BEGIN CATCH IF ERROR_NUMBER()=547 THROW 50116,N'Tầng đã có phòng/công tơ/dữ liệu liên quan, không thể xóa',1; THROW; END CATCH
END
GO

/* ---------- 01.1 Phòng ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_Room_Save
    @RoomId INT=NULL,@FloorId INT,@RoomCode VARCHAR(20),@RoomName NVARCHAR(100),
    @MinX DECIMAL(10,2),@MinY DECIMAL(10,2),@MaxX DECIMAL(10,2),@MaxY DECIMAL(10,2)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @RoomCode=UPPER(LTRIM(RTRIM(@RoomCode)));
    IF ISNULL(@RoomCode,'')='' OR ISNULL(@RoomName,N'')=N'' THROW 50120,N'Mã và tên phòng là bắt buộc',1;
    IF @MaxX<=@MinX OR @MaxY<=@MinY THROW 50110,N'Ranh giới mặt bằng không hợp lệ (Max phải lớn hơn Min)',1;
    IF EXISTS(SELECT 1 FROM dbo.Rooms WHERE RoomCode=@RoomCode AND RoomId<>ISNULL(@RoomId,0)) THROW 50121,N'Mã phòng đã tồn tại',1;
    DECLARE @g geometry=geometry::STGeomFromText(dbo.fn_PolygonWkt(@MinX,@MinY,@MaxX,@MaxY),0);
    IF NOT EXISTS(SELECT 1 FROM dbo.Floors WHERE FloorId=@FloorId AND Boundary.STContains(@g)=1)
        THROW 50122,N'Phòng nằm ngoài ranh giới mặt bằng của tầng',1;
    IF @RoomId IS NOT NULL AND EXISTS(SELECT 1 FROM dbo.Meters m WHERE m.RoomId=@RoomId AND @g.STContains(m.Location)=0)
        THROW 50115,N'Ranh giới mới làm một số công tơ nằm ngoài phòng',1;
    DECLARE @area DECIMAL(12,2)=CAST(@g.STArea() AS DECIMAL(12,2));
    IF @RoomId IS NULL
    BEGIN
        INSERT dbo.Rooms(FloorId,RoomCode,RoomName,MinX,MinY,MaxX,MaxY,Boundary,AreaM2) VALUES(@FloorId,@RoomCode,@RoomName,@MinX,@MinY,@MaxX,@MaxY,@g,@area);
        SELECT SCOPE_IDENTITY() AS RoomId;
    END
    ELSE
    BEGIN   -- khóa mã phòng khi sửa
        UPDATE dbo.Rooms SET RoomName=@RoomName,MinX=@MinX,MinY=@MinY,MaxX=@MaxX,MaxY=@MaxY,Boundary=@g,AreaM2=@area WHERE RoomId=@RoomId;
        SELECT @RoomId AS RoomId;
    END
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Room_List @FloorId INT=NULL
AS BEGIN SET NOCOUNT ON;
    SELECT r.RoomId,r.FloorId,f.FloorName,r.RoomCode,r.RoomName,r.MinX,r.MinY,r.MaxX,r.MaxY,r.AreaM2
    FROM dbo.Rooms r JOIN dbo.Floors f ON f.FloorId=r.FloorId WHERE @FloorId IS NULL OR r.FloorId=@FloorId ORDER BY f.FloorNo,r.RoomCode; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Room_Delete @RoomId INT
AS BEGIN SET NOCOUNT ON;
    BEGIN TRY DELETE dbo.Rooms WHERE RoomId=@RoomId; END TRY
    BEGIN CATCH IF ERROR_NUMBER()=547 THROW 50123,N'Phòng đang có công tơ/định mức/kế hoạch, không thể xóa',1; THROW; END CATCH
END
GO

/* ---------- 01.2 Khai báo công tơ ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_Meter_Save
    @MeterId INT=NULL,@MeterCode VARCHAR(30),@MeterName NVARCHAR(100),@EnergyTypeId INT,
    @Manufacturer NVARCHAR(100)=NULL,@Model NVARCHAR(100)=NULL,@SerialNo NVARCHAR(50)=NULL,@Specification NVARCHAR(300)=NULL,
    @MaxValuePerInterval DECIMAL(18,3)=NULL,@IntervalMinutes INT=60,
    @FloorId INT,@RoomId INT=NULL,@LocX DECIMAL(10,2),@LocY DECIMAL(10,2),
    @InstallDate DATE=NULL,@Status VARCHAR(10)='ACTIVE',@UserId INT=NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @MeterCode=UPPER(LTRIM(RTRIM(@MeterCode)));
    IF ISNULL(@MeterCode,'')='' THROW 50130,N'Mã công tơ là bắt buộc',1;
    IF ISNULL(@MeterName,N'')=N'' THROW 50131,N'Tên công tơ là bắt buộc',1;
    IF NOT EXISTS(SELECT 1 FROM dbo.EnergyTypes WHERE EnergyTypeId=@EnergyTypeId) THROW 50132,N'Loại năng lượng không hợp lệ',1;
    IF @FloorId IS NULL OR NOT EXISTS(SELECT 1 FROM dbo.Floors WHERE FloorId=@FloorId) THROW 50133,N'Công tơ phải gắn với một tầng (BR02)',1;
    IF @RoomId IS NOT NULL AND NOT EXISTS(SELECT 1 FROM dbo.Rooms WHERE RoomId=@RoomId AND FloorId=@FloorId)
        THROW 50134,N'Phòng được chọn không thuộc tầng đã chọn',1;
    -- 01.3 BR01: trùng mã
    IF EXISTS(SELECT 1 FROM dbo.Meters WHERE MeterCode=@MeterCode AND MeterId<>ISNULL(@MeterId,0))
        THROW 50135,N'Mã công tơ đã tồn tại trên hệ thống',1;
    -- 01.4 BR02: tọa độ trong mặt bằng
    IF dbo.fn_IsPointInside(@FloorId,@RoomId,@LocX,@LocY)=0
        THROW 50136,N'Tọa độ chọn nằm ngoài phạm vi mặt bằng tòa nhà',1;
    DECLARE @pt geometry=geometry::Point(@LocX,@LocY,0);
    IF @MeterId IS NULL
    BEGIN
        INSERT dbo.Meters(MeterCode,MeterName,EnergyTypeId,Manufacturer,Model,SerialNo,Specification,MaxValuePerInterval,IntervalMinutes,
                          FloorId,RoomId,LocX,LocY,Location,InstallDate,Status,CreatedBy)
        VALUES(@MeterCode,@MeterName,@EnergyTypeId,@Manufacturer,@Model,@SerialNo,@Specification,@MaxValuePerInterval,@IntervalMinutes,
               @FloorId,@RoomId,@LocX,@LocY,@pt,@InstallDate,@Status,@UserId);
        SELECT SCOPE_IDENTITY() AS MeterId;
    END
    ELSE
    BEGIN   -- khóa MeterCode khi sửa; không đổi loại năng lượng nếu đã có dữ liệu
        IF EXISTS(SELECT 1 FROM dbo.Meters WHERE MeterId=@MeterId AND EnergyTypeId<>@EnergyTypeId)
           AND EXISTS(SELECT 1 FROM dbo.RawTelemetry WHERE MeterId=@MeterId)
            THROW 50137,N'Công tơ đã có dữ liệu, không được đổi loại năng lượng',1;
        UPDATE dbo.Meters SET MeterName=@MeterName,EnergyTypeId=@EnergyTypeId,Manufacturer=@Manufacturer,Model=@Model,SerialNo=@SerialNo,
               Specification=@Specification,MaxValuePerInterval=@MaxValuePerInterval,IntervalMinutes=@IntervalMinutes,
               FloorId=@FloorId,RoomId=@RoomId,LocX=@LocX,LocY=@LocY,Location=@pt,InstallDate=@InstallDate,Status=@Status,UpdatedAt=SYSDATETIME()
         WHERE MeterId=@MeterId;
        SELECT @MeterId AS MeterId;
    END
END
GO
CREATE OR ALTER VIEW dbo.vw_MeterDetail AS
SELECT m.MeterId,m.MeterCode,m.MeterName,m.EnergyTypeId,e.Name AS EnergyName,e.Unit,m.Manufacturer,m.Model,m.SerialNo,m.Specification,
       m.MaxValuePerInterval,m.IntervalMinutes,b.BuildingId,b.BuildingName,f.FloorId,f.FloorName,f.FloorNo,r.RoomId,r.RoomName,
       m.LocX,m.LocY,m.InstallDate,m.Status,m.LastReadingAt
FROM dbo.Meters m
JOIN dbo.EnergyTypes e ON e.EnergyTypeId=m.EnergyTypeId
JOIN dbo.Floors f ON f.FloorId=m.FloorId
JOIN dbo.Buildings b ON b.BuildingId=f.BuildingId
LEFT JOIN dbo.Rooms r ON r.RoomId=m.RoomId;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Meter_List
    @BuildingId INT=NULL,@FloorId INT=NULL,@EnergyTypeId INT=NULL,@Status VARCHAR(10)=NULL,@Keyword NVARCHAR(100)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM dbo.vw_MeterDetail v
    WHERE (@BuildingId IS NULL OR v.BuildingId=@BuildingId) AND (@FloorId IS NULL OR v.FloorId=@FloorId)
      AND (@EnergyTypeId IS NULL OR v.EnergyTypeId=@EnergyTypeId) AND (@Status IS NULL OR v.Status=@Status)
      AND (@Keyword IS NULL OR v.MeterCode LIKE N'%'+@Keyword+N'%' OR v.MeterName LIKE N'%'+@Keyword+N'%')
    ORDER BY v.BuildingName,v.FloorNo,v.MeterCode;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Meter_Lookup @EnergyTypeId INT=NULL,@ActiveOnly BIT=0
AS BEGIN SET NOCOUNT ON;
    SELECT MeterId,MeterCode+N' - '+MeterName AS Display,MeterCode,EnergyTypeId FROM dbo.Meters
    WHERE (@EnergyTypeId IS NULL OR EnergyTypeId=@EnergyTypeId) AND (@ActiveOnly=0 OR Status='ACTIVE') ORDER BY MeterCode; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_EnergyType_List AS BEGIN SET NOCOUNT ON;
    SELECT EnergyTypeId,Code,Name,Unit,PricePerUnit FROM dbo.EnergyTypes ORDER BY EnergyTypeId; END
GO

/* ---------- 01.5 Trạng thái / xóa ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_Meter_SetStatus @MeterId INT,@Status VARCHAR(10)
AS BEGIN SET NOCOUNT ON;
    IF @Status NOT IN ('ACTIVE','INACTIVE','FAULTY') THROW 50138,N'Trạng thái công tơ không hợp lệ',1;
    UPDATE dbo.Meters SET Status=@Status,UpdatedAt=SYSDATETIME() WHERE MeterId=@MeterId; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Meter_Delete @MeterId INT
AS BEGIN SET NOCOUNT ON;
    BEGIN TRY DELETE dbo.Meters WHERE MeterId=@MeterId; END TRY
    BEGIN CATCH IF ERROR_NUMBER()=547 THROW 50139,N'Công tơ đã phát sinh dữ liệu chỉ số/Audit Log, chỉ có thể chuyển sang Ngưng hoạt động',1; THROW; END CATCH
END
GO

/* ---------- 01.6 Sơ đồ mặt bằng: 3 tập kết quả (tầng, phòng, công tơ) ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_FloorPlan_Get @FloorId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT FloorId,FloorName,MinX,MinY,MaxX,MaxY FROM dbo.Floors WHERE FloorId=@FloorId;
    SELECT RoomId,RoomCode,RoomName,MinX,MinY,MaxX,MaxY FROM dbo.Rooms WHERE FloorId=@FloorId;
    SELECT MeterId,MeterCode,MeterName,EnergyTypeId,LocX,LocY,Status FROM dbo.Meters WHERE FloorId=@FloorId;
END
GO
/* =====================================================================
   UC02 - THU THẬP VÀ TỔNG HỢP DỮ LIỆU TIÊU THỤ
   Phân rã:
     02.1 Tiếp nhận & xác thực gói dữ liệu IoT (BR03)   -> usp_Telemetry_IngestBatch (TVP)  «include»
     02.2 Tổng hợp theo giờ/ngày/tháng                    -> usp_Aggregate_Meter, usp_Aggregate_Run «include»
     02.3 Phát metric hệ thống (OpenTelemetry)            -> usp_Metric_Emit (00_Common)   «include»
     02.4 Ghi nhận chỉ số thủ công khi mất IoT            -> usp_Telemetry_ManualEntry     «extend»
     02.5 Ghi log tiếp nhận / từ chối                     -> IngestLog
   Quy ước: ReadingValue = lượng tiêu thụ trong 1 chu kỳ đo (kWh/m3 mỗi chu kỳ).
   Trạng thái chất lượng: PENDING (chờ quét) -> VALID | ANOMALY -> CLEANED (sau UC07).
   Transaction: ghi dữ liệu thô + quét + tổng hợp nằm trong 1 giao dịch (usp_Telemetry_IngestBatch).
   ===================================================================== */
USE EnergyPortalDB;
GO
IF OBJECT_ID(N'dbo.RawTelemetry', N'U') IS NULL
CREATE TABLE dbo.RawTelemetry(
    RawId        BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_RawTelemetry PRIMARY KEY,
    MeterId      INT           NOT NULL CONSTRAINT FK_Raw_Meter REFERENCES dbo.Meters(MeterId),
    ReadingTime  DATETIME2(0)  NOT NULL,                                       -- BR03: timestamp bắt buộc
    ReceivedAt   DATETIME2(0)  NOT NULL CONSTRAINT DF_Raw_Received DEFAULT SYSDATETIME(),
    ReadingValue DECIMAL(18,3) NULL,
    CleanedValue DECIMAL(18,3) NULL,
    SourceType   VARCHAR(10)   NOT NULL CONSTRAINT DF_Raw_Source DEFAULT 'IOT',
    RecordedBy   INT           NULL CONSTRAINT FK_Raw_User REFERENCES dbo.Users(UserId),
    QualityStatus VARCHAR(10)  NOT NULL CONSTRAINT DF_Raw_Quality DEFAULT 'PENDING',
    CleanedAt    DATETIME2(0)  NULL,
    EffectiveValue AS (CASE WHEN QualityStatus='CLEANED' THEN CleanedValue ELSE ReadingValue END),
    CONSTRAINT UQ_Raw_MeterTime UNIQUE(MeterId,ReadingTime),
    CONSTRAINT CK_Raw_Source  CHECK (SourceType IN ('IOT','MANUAL','SYSTEM')),
    CONSTRAINT CK_Raw_Quality CHECK (QualityStatus IN ('PENDING','VALID','ANOMALY','CLEANED')),
    CONSTRAINT CK_Raw_Manual  CHECK (SourceType<>'MANUAL' OR RecordedBy IS NOT NULL),   -- lưu người nhập thủ công
    CONSTRAINT CK_Raw_Value   CHECK (ReadingValue IS NOT NULL OR SourceType='SYSTEM')
);
GO
CREATE INDEX IX_Raw_Quality ON dbo.RawTelemetry(QualityStatus) INCLUDE(MeterId,ReadingTime);
GO
IF OBJECT_ID(N'dbo.IngestLog', N'U') IS NULL
CREATE TABLE dbo.IngestLog(
    LogId        BIGINT IDENTITY(1,1) CONSTRAINT PK_IngestLog PRIMARY KEY,
    BatchId      UNIQUEIDENTIFIER NOT NULL,
    ReceivedAt   DATETIME2(0)  NOT NULL CONSTRAINT DF_IngestLog_At DEFAULT SYSDATETIME(),
    SourceType   VARCHAR(10)   NOT NULL,
    MeterCode    VARCHAR(30)   NULL,
    ReadingTime  DATETIME2(0)  NULL,
    ReadingValue DECIMAL(18,3) NULL,
    Result       VARCHAR(10)   NOT NULL,                  -- REJECTED | BATCH
    Reason       NVARCHAR(300) NULL
);
GO
IF OBJECT_ID(N'dbo.EnergyAggregates', N'U') IS NULL
CREATE TABLE dbo.EnergyAggregates(
    AggId         BIGINT IDENTITY(1,1) CONSTRAINT PK_EnergyAggregates PRIMARY KEY,
    MeterId       INT           NOT NULL CONSTRAINT FK_Agg_Meter REFERENCES dbo.Meters(MeterId),
    PeriodType    VARCHAR(5)    NOT NULL,
    PeriodStart   DATETIME2(0)  NOT NULL,
    TotalValue    DECIMAL(18,3) NOT NULL,              -- chỉ cộng dữ liệu VALID/CLEANED (BR08)
    ValidCount    INT NOT NULL, AnomalyCount INT NOT NULL, PendingCount INT NOT NULL, ExpectedCount INT NOT NULL,
    IsComplete    BIT           NOT NULL,
    UpdatedAt     DATETIME2(0)  NOT NULL CONSTRAINT DF_Agg_Updated DEFAULT SYSDATETIME(),
    CONSTRAINT UQ_Agg UNIQUE(MeterId,PeriodType,PeriodStart),
    CONSTRAINT CK_Agg_Type CHECK (PeriodType IN ('HOUR','DAY','MONTH'))
);
GO
CREATE INDEX IX_Agg_TypeStart ON dbo.EnergyAggregates(PeriodType,PeriodStart) INCLUDE(MeterId,TotalValue,IsComplete);
GO

/* ---------- 02.2 Tổng hợp ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_Aggregate_Meter @MeterId INT,@From DATETIME2(0),@To DATETIME2(0)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @own BIT=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
    BEGIN TRY
        DECLARE @iv INT=(SELECT IntervalMinutes FROM dbo.Meters WHERE MeterId=@MeterId);
        IF @iv IS NULL THROW 50310,N'Công tơ không tồn tại',1;
        IF @To<@From THROW 50311,N'Khoảng thời gian tổng hợp không hợp lệ',1;
        DECLARE @h0 DATETIME2(0)=DATEADD(HOUR,DATEDIFF(HOUR,'19000101',@From),'19000101');
        DECLARE @h1 DATETIME2(0)=DATEADD(HOUR,1,DATEADD(HOUR,DATEDIFF(HOUR,'19000101',@To),'19000101'));
        DECLARE @d0 DATETIME2(0)=CAST(CAST(@From AS DATE) AS DATETIME2(0));
        DECLARE @d1 DATETIME2(0)=DATEADD(DAY,1,CAST(CAST(@To AS DATE) AS DATETIME2(0)));
        DECLARE @m0 DATETIME2(0)=CAST(DATEFROMPARTS(YEAR(@From),MONTH(@From),1) AS DATETIME2(0));
        DECLARE @m1 DATETIME2(0)=DATEADD(MONTH,1,CAST(DATEFROMPARTS(YEAR(@To),MONTH(@To),1) AS DATETIME2(0)));
        IF @own=1 BEGIN TRAN;

        DELETE dbo.EnergyAggregates WHERE MeterId=@MeterId AND (
              (PeriodType='HOUR'  AND PeriodStart>=@h0 AND PeriodStart<@h1)
           OR (PeriodType='DAY'   AND PeriodStart>=@d0 AND PeriodStart<@d1)
           OR (PeriodType='MONTH' AND PeriodStart>=@m0 AND PeriodStart<@m1));

        SELECT ReadingTime, QualityStatus AS Q, EffectiveValue AS V
        INTO #agg_r FROM dbo.RawTelemetry WHERE MeterId=@MeterId AND ReadingTime>=@m0 AND ReadingTime<@m1;

        INSERT dbo.EnergyAggregates(MeterId,PeriodType,PeriodStart,TotalValue,ValidCount,AnomalyCount,PendingCount,ExpectedCount,IsComplete)
        SELECT @MeterId,'HOUR',k,tot,vc,ac,pc,60/@iv,CASE WHEN vc>=60/@iv AND ac=0 AND pc=0 THEN 1 ELSE 0 END
        FROM (SELECT CAST(DATEADD(HOUR,DATEDIFF(HOUR,'19000101',ReadingTime),'19000101') AS DATETIME2(0)) AS k,
                     SUM(CASE WHEN Q IN ('VALID','CLEANED') THEN ISNULL(V,0) ELSE 0 END) AS tot,
                     SUM(CASE WHEN Q IN ('VALID','CLEANED') AND V IS NOT NULL THEN 1 ELSE 0 END) AS vc,
                     SUM(CASE WHEN Q='ANOMALY' THEN 1 ELSE 0 END) AS ac,
                     SUM(CASE WHEN Q='PENDING' THEN 1 ELSE 0 END) AS pc
              FROM #agg_r WHERE ReadingTime>=@h0 AND ReadingTime<@h1
              GROUP BY DATEADD(HOUR,DATEDIFF(HOUR,'19000101',ReadingTime),'19000101')) x;

        INSERT dbo.EnergyAggregates(MeterId,PeriodType,PeriodStart,TotalValue,ValidCount,AnomalyCount,PendingCount,ExpectedCount,IsComplete)
        SELECT @MeterId,'DAY',k,tot,vc,ac,pc,1440/@iv,CASE WHEN vc>=1440/@iv AND ac=0 AND pc=0 THEN 1 ELSE 0 END
        FROM (SELECT CAST(CAST(ReadingTime AS DATE) AS DATETIME2(0)) AS k,
                     SUM(CASE WHEN Q IN ('VALID','CLEANED') THEN ISNULL(V,0) ELSE 0 END) AS tot,
                     SUM(CASE WHEN Q IN ('VALID','CLEANED') AND V IS NOT NULL THEN 1 ELSE 0 END) AS vc,
                     SUM(CASE WHEN Q='ANOMALY' THEN 1 ELSE 0 END) AS ac,
                     SUM(CASE WHEN Q='PENDING' THEN 1 ELSE 0 END) AS pc
              FROM #agg_r WHERE ReadingTime>=@d0 AND ReadingTime<@d1
              GROUP BY CAST(ReadingTime AS DATE)) x;

        INSERT dbo.EnergyAggregates(MeterId,PeriodType,PeriodStart,TotalValue,ValidCount,AnomalyCount,PendingCount,ExpectedCount,IsComplete)
        SELECT @MeterId,'MONTH',k,tot,vc,ac,pc,DAY(EOMONTH(k))*1440/@iv,CASE WHEN vc>=DAY(EOMONTH(k))*1440/@iv AND ac=0 AND pc=0 THEN 1 ELSE 0 END
        FROM (SELECT CAST(DATEFROMPARTS(YEAR(ReadingTime),MONTH(ReadingTime),1) AS DATETIME2(0)) AS k,
                     SUM(CASE WHEN Q IN ('VALID','CLEANED') THEN ISNULL(V,0) ELSE 0 END) AS tot,
                     SUM(CASE WHEN Q IN ('VALID','CLEANED') AND V IS NOT NULL THEN 1 ELSE 0 END) AS vc,
                     SUM(CASE WHEN Q='ANOMALY' THEN 1 ELSE 0 END) AS ac,
                     SUM(CASE WHEN Q='PENDING' THEN 1 ELSE 0 END) AS pc
              FROM #agg_r WHERE ReadingTime>=@m0 AND ReadingTime<@m1
              GROUP BY YEAR(ReadingTime),MONTH(ReadingTime)) x;

        DROP TABLE #agg_r;
        IF @own=1 COMMIT;
    END TRY
    BEGIN CATCH
        IF @own=1 AND @@TRANCOUNT>0 ROLLBACK; THROW;
    END CATCH
END
GO
/* Tổng hợp lại cho 1 công tơ hoặc toàn bộ công tơ trong khoảng thời gian (nút "Chạy tổng hợp") */
CREATE OR ALTER PROCEDURE dbo.usp_Aggregate_Run @MeterId INT=NULL,@From DATETIME2(0)=NULL,@To DATETIME2(0)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 DATETIME2=SYSDATETIME(),@n INT=0;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT r.MeterId,ISNULL(@From,MIN(r.ReadingTime)),ISNULL(@To,MAX(r.ReadingTime))
        FROM dbo.RawTelemetry r WHERE (@MeterId IS NULL OR r.MeterId=@MeterId)
          AND (@From IS NULL OR r.ReadingTime>=@From) AND (@To IS NULL OR r.ReadingTime<=@To)
        GROUP BY r.MeterId;
    DECLARE @m INT,@a DATETIME2(0),@b DATETIME2(0);
    OPEN c; FETCH NEXT FROM c INTO @m,@a,@b;
    WHILE @@FETCH_STATUS=0
    BEGIN
        EXEC dbo.usp_Aggregate_Meter @m,@a,@b; SET @n+=1;
        FETCH NEXT FROM c INTO @m,@a,@b;
    END
    CLOSE c; DEALLOCATE c;
    DECLARE @ms DECIMAL(18,3)=DATEDIFF(MILLISECOND,@t0,SYSDATETIME());
    EXEC dbo.usp_Metric_Emit 'aggregation_duration_ms',@ms,'ms',N'manual_run';
    SELECT @n AS MetersAggregated,@ms AS ElapsedMs;
END
GO

/* ---------- 02.1 Tiếp nhận lô dữ liệu (IoT / thủ công) ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_Telemetry_IngestBatch
    @Batch dbo.TelemetryBatchType READONLY,
    @Source VARCHAR(10)='IOT', @RecordedBy INT=NULL,
    @Accepted INT=0 OUTPUT, @Rejected INT=0 OUTPUT, @AnomalyFound INT=0 OUTPUT, @Quiet BIT=0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @own BIT=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
    DECLARE @t0 DATETIME2=SYSDATETIME(),@batchId UNIQUEIDENTIFIER=NEWID();
    BEGIN TRY
        IF @Source NOT IN ('IOT','MANUAL') THROW 50301,N'Nguồn dữ liệu không hợp lệ',1;
        IF @Source='MANUAL' AND @RecordedBy IS NULL THROW 50302,N'Ghi nhận thủ công bắt buộc phải có người nhập',1;
        DECLARE @tol INT=CAST(dbo.fn_SettingNum('FUTURE_TOLERANCE_MIN') AS INT);

        CREATE TABLE #b(Seq INT IDENTITY(1,1) PRIMARY KEY,MeterCode VARCHAR(30),ReadingTime DATETIME2(0),ReadingValue DECIMAL(18,3),
                        MeterId INT,MStatus VARCHAR(10),Reason NVARCHAR(200));
        INSERT #b(MeterCode,ReadingTime,ReadingValue) SELECT UPPER(LTRIM(RTRIM(MeterCode))),ReadingTime,ReadingValue FROM @Batch;
        CREATE INDEX IX_b ON #b(MeterId,ReadingTime,Seq);
        UPDATE b SET MeterId=m.MeterId,MStatus=m.Status FROM #b b JOIN dbo.Meters m ON m.MeterCode=b.MeterCode;
        UPDATE #b SET Reason=CASE
            WHEN MeterId IS NULL THEN N'Mã công tơ không tồn tại'
            WHEN MStatus='INACTIVE' THEN N'Công tơ đã ngưng hoạt động'
            WHEN ReadingTime IS NULL THEN N'Thiếu dấu thời gian (timestamp) - BR03'
            WHEN ReadingTime>DATEADD(MINUTE,@tol,SYSDATETIME()) THEN N'Dấu thời gian nằm ở tương lai'
            WHEN ReadingValue IS NULL THEN N'Thiếu giá trị chỉ số'
            WHEN @Source='MANUAL' AND ReadingValue<0 THEN N'Chỉ số nhập thủ công phải >= 0'
            END;
        UPDATE b SET Reason=N'Trùng mốc thời gian trong cùng lô'
          FROM #b b WHERE b.Reason IS NULL AND EXISTS(SELECT 1 FROM #b x WHERE x.MeterId=b.MeterId AND x.ReadingTime=b.ReadingTime AND x.Seq<b.Seq AND x.Reason IS NULL);
        UPDATE b SET Reason=N'Đã có dữ liệu tại mốc thời gian này'
          FROM #b b WHERE b.Reason IS NULL AND EXISTS(SELECT 1 FROM dbo.RawTelemetry r WHERE r.MeterId=b.MeterId AND r.ReadingTime=b.ReadingTime AND r.ReadingValue IS NOT NULL);

        INSERT dbo.IngestLog(BatchId,SourceType,MeterCode,ReadingTime,ReadingValue,Result,Reason)
        SELECT @batchId,@Source,MeterCode,ReadingTime,ReadingValue,'REJECTED',Reason FROM #b WHERE Reason IS NOT NULL;
        SET @Rejected=@@ROWCOUNT;
        SET @Accepted=(SELECT COUNT(*) FROM #b WHERE Reason IS NULL);
        SET @AnomalyFound=0;

        IF @Accepted>0
        BEGIN
            IF @own=1 BEGIN TRAN;
            -- lấp chỗ khuyết (bản ghi SYSTEM do UC05 tạo) khi có dữ liệu bổ sung
            DECLARE @filled TABLE(RawId BIGINT);
            UPDATE r SET ReadingValue=b.ReadingValue,CleanedValue=NULL,CleanedAt=NULL,SourceType=@Source,RecordedBy=@RecordedBy,
                         QualityStatus='PENDING',ReceivedAt=SYSDATETIME()
            OUTPUT inserted.RawId INTO @filled
            FROM dbo.RawTelemetry r JOIN #b b ON b.MeterId=r.MeterId AND b.ReadingTime=r.ReadingTime
            WHERE b.Reason IS NULL AND r.ReadingValue IS NULL;
            UPDATE dbo.DataAnomalies SET Status='RESOLVED',ResolvedAt=SYSDATETIME(),Note=N'Đã có dữ liệu bổ sung tại mốc này'
             WHERE Status='OPEN' AND RawId IN (SELECT RawId FROM @filled);

            INSERT dbo.RawTelemetry(MeterId,ReadingTime,ReadingValue,SourceType,RecordedBy,QualityStatus)
            SELECT b.MeterId,b.ReadingTime,b.ReadingValue,@Source,@RecordedBy,'PENDING'
            FROM #b b WHERE b.Reason IS NULL
              AND NOT EXISTS(SELECT 1 FROM dbo.RawTelemetry r WHERE r.MeterId=b.MeterId AND r.ReadingTime=b.ReadingTime);

            UPDATE m SET LastReadingAt=x.mx FROM dbo.Meters m
            JOIN (SELECT MeterId,MAX(ReadingTime) mx FROM #b WHERE Reason IS NULL GROUP BY MeterId) x ON x.MeterId=m.MeterId
            WHERE m.LastReadingAt IS NULL OR m.LastReadingAt<x.mx;

            DECLARE @mid INT,@mn DATETIME2(0),@mx DATETIME2(0),@sc INT,@an INT,@ta DATETIME2;
            DECLARE c CURSOR LOCAL FAST_FORWARD FOR
                SELECT MeterId,MIN(ReadingTime),MAX(ReadingTime) FROM #b WHERE Reason IS NULL GROUP BY MeterId;
            OPEN c; FETCH NEXT FROM c INTO @mid,@mn,@mx;
            WHILE @@FETCH_STATUS=0
            BEGIN
                SET @an=0;
                EXEC dbo.usp_DQ_Scan @MeterId=@mid,@From=@mn,@To=@mx,@Mode='AUTO',@Aggregate=0,@Quiet=1,@ScannedCount=@sc OUTPUT,@AnomalyCount=@an OUTPUT;
                SET @AnomalyFound+=@an;
                SET @ta=SYSDATETIME();
                EXEC dbo.usp_Aggregate_Meter @mid,@mn,@mx;
                DECLARE @agms DECIMAL(18,3)=DATEDIFF(MILLISECOND,@ta,SYSDATETIME());
                EXEC dbo.usp_Metric_Emit 'aggregation_duration_ms',@agms,'ms',@Source;
                FETCH NEXT FROM c INTO @mid,@mn,@mx;
            END
            CLOSE c; DEALLOCATE c;
            IF @own=1 COMMIT;
        END

        DECLARE @ms DECIMAL(18,3)=DATEDIFF(MILLISECOND,@t0,SYSDATETIME());
        DECLARE @sum NVARCHAR(300)=N'Nhận '+CAST(@Accepted AS NVARCHAR(10))+N' bản ghi, từ chối '+CAST(@Rejected AS NVARCHAR(10))+
                                   N', phát hiện '+CAST(@AnomalyFound AS NVARCHAR(10))+N' bất thường dữ liệu';
        INSERT dbo.IngestLog(BatchId,SourceType,Result,Reason) VALUES(@batchId,@Source,'BATCH',@sum);
        DECLARE @fa DECIMAL(18,3)=@Accepted,@fr DECIMAL(18,3)=@Rejected;
        EXEC dbo.usp_Metric_Emit 'telemetry_ingest_accepted_total',@fa,'count',@Source;
        EXEC dbo.usp_Metric_Emit 'telemetry_ingest_rejected_total',@fr,'count',@Source;
        EXEC dbo.usp_Metric_Emit 'telemetry_ingest_duration_ms',@ms,'ms',@Source;
        IF @Quiet=0 SELECT @Accepted AS Accepted,@Rejected AS Rejected,@AnomalyFound AS AnomalyFound,@ms AS ElapsedMs;
    END TRY
    BEGIN CATCH
        IF @own=1 AND @@TRANCOUNT>0 ROLLBACK;
        THROW;
    END CATCH
END
GO

/* ---------- 02.4 Ghi nhận chỉ số thủ công (extend) ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_Telemetry_ManualEntry
    @MeterId INT,@ReadingTime DATETIME2(0),@Value DECIMAL(18,3),@RecordedBy INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @code VARCHAR(30),@iv INT;
    SELECT @code=MeterCode,@iv=IntervalMinutes FROM dbo.Meters WHERE MeterId=@MeterId;
    IF @code IS NULL THROW 50303,N'Vui lòng chọn công tơ hợp lệ',1;
    IF @Value IS NULL OR @Value<0 THROW 50304,N'Chỉ số tiêu thụ (kWh) phải >= 0',1;
    DECLARE @t DATETIME2(0)=DATEADD(MINUTE,(DATEDIFF(MINUTE,'19000101',@ReadingTime)/@iv)*@iv,'19000101');   -- căn theo chu kỳ đo
    DECLARE @b dbo.TelemetryBatchType; INSERT @b VALUES(@code,@t,@Value);
    DECLARE @a INT,@r INT,@x INT;
    EXEC dbo.usp_Telemetry_IngestBatch @b,'MANUAL',@RecordedBy,@a OUTPUT,@r OUTPUT,@x OUTPUT,@Quiet=1;
    IF @r>0
    BEGIN
        DECLARE @m NVARCHAR(300)=(SELECT TOP 1 Reason FROM dbo.IngestLog WHERE MeterCode=@code AND Result='REJECTED' ORDER BY LogId DESC);
        THROW 50305,@m,1;
    END
    SELECT @a AS Accepted,@x AS AnomalyFound,@t AS ReadingTimeAligned;
END
GO

/* ---------- Truy vấn cho màn hình ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_Telemetry_List
    @MeterId INT=NULL,@From DATETIME2(0)=NULL,@To DATETIME2(0)=NULL,@Status VARCHAR(10)=NULL,@Source VARCHAR(10)=NULL,@Top INT=2000
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Top) r.RawId,m.MeterCode,r.ReadingTime,r.ReadingValue,r.CleanedValue,r.EffectiveValue,r.SourceType,r.QualityStatus,
           u.FullName AS RecordedByName,r.ReceivedAt
    FROM dbo.RawTelemetry r JOIN dbo.Meters m ON m.MeterId=r.MeterId LEFT JOIN dbo.Users u ON u.UserId=r.RecordedBy
    WHERE (@MeterId IS NULL OR r.MeterId=@MeterId) AND (@From IS NULL OR r.ReadingTime>=@From) AND (@To IS NULL OR r.ReadingTime<=@To)
      AND (@Status IS NULL OR r.QualityStatus=@Status) AND (@Source IS NULL OR r.SourceType=@Source)
    ORDER BY r.ReadingTime DESC,m.MeterCode;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_IngestLog_List @Top INT=500
AS BEGIN SET NOCOUNT ON;
    SELECT TOP (@Top) LogId,ReceivedAt,SourceType,MeterCode,ReadingTime,ReadingValue,Result,Reason FROM dbo.IngestLog ORDER BY LogId DESC; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Aggregate_List
    @MeterId INT=NULL,@PeriodType VARCHAR(5)='DAY',@From DATETIME2(0)=NULL,@To DATETIME2(0)=NULL,@Top INT=3000
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Top) m.MeterCode,a.PeriodType,a.PeriodStart,a.TotalValue,e.Unit,a.ValidCount,a.ExpectedCount,a.AnomalyCount,a.PendingCount,a.IsComplete,a.UpdatedAt
    FROM dbo.EnergyAggregates a JOIN dbo.Meters m ON m.MeterId=a.MeterId JOIN dbo.EnergyTypes e ON e.EnergyTypeId=m.EnergyTypeId
    WHERE a.PeriodType=@PeriodType AND (@MeterId IS NULL OR a.MeterId=@MeterId)
      AND (@From IS NULL OR a.PeriodStart>=@From) AND (@To IS NULL OR a.PeriodStart<=@To)
    ORDER BY a.PeriodStart DESC,m.MeterCode;
END
GO
/* =====================================================================
   UC03 - THIẾT LẬP VÀ QUẢN LÝ ĐỊNH MỨC TIÊU THỤ
   Phân rã:
     03.1 Xem định mức theo khu vực (tòa nhà/tầng/phòng)   -> usp_Quota_List
     03.2 Kiểm tra giá trị định mức > 0 (BR04) «include»    -> CK_Quotas_Value + usp_Quota_Save
     03.3 Kiểm tra chồng chéo khung thời gian (BR04) «include» -> usp_Quota_Save
     03.4 Áp dụng / sửa định mức (khóa mã khi sửa)          -> usp_Quota_Save
     03.5 Ngưng áp dụng / xóa định mức                      -> usp_Quota_SetActive, usp_Quota_Delete
   Khu vực: BuildingId (bắt buộc) + FloorId (tùy chọn) + RoomId (tùy chọn).
   ===================================================================== */
USE EnergyPortalDB;
GO
IF OBJECT_ID(N'dbo.Quotas', N'U') IS NULL
CREATE TABLE dbo.Quotas(
    QuotaId        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Quotas PRIMARY KEY,
    QuotaCode      VARCHAR(20)   NOT NULL CONSTRAINT UQ_Quotas_Code UNIQUE,
    BuildingId     INT           NOT NULL CONSTRAINT FK_Quotas_Building REFERENCES dbo.Buildings(BuildingId),
    FloorId        INT           NULL CONSTRAINT FK_Quotas_Floor REFERENCES dbo.Floors(FloorId),
    RoomId         INT           NULL CONSTRAINT FK_Quotas_Room  REFERENCES dbo.Rooms(RoomId),
    EnergyTypeId   INT           NOT NULL CONSTRAINT FK_Quotas_Energy REFERENCES dbo.EnergyTypes(EnergyTypeId),
    PeriodType     VARCHAR(5)    NOT NULL,                           -- HOUR / DAY / MONTH
    QuotaValue     DECIMAL(18,3) NOT NULL,                           -- ngưỡng định mức
    WarningPercent DECIMAL(5,2)  NOT NULL CONSTRAINT DF_Quotas_Warn DEFAULT 80,   -- >= % này: cảnh báo vàng
    EffectiveFrom  DATE          NOT NULL,
    EffectiveTo    DATE          NULL,
    TimeFrom       TIME(0)       NOT NULL CONSTRAINT DF_Quotas_TF DEFAULT '00:00:00',
    TimeTo         TIME(0)       NOT NULL CONSTRAINT DF_Quotas_TT DEFAULT '23:59:59',
    IsActive       BIT           NOT NULL CONSTRAINT DF_Quotas_Active DEFAULT 1,
    Note           NVARCHAR(200) NULL,
    CreatedBy      INT           NULL CONSTRAINT FK_Quotas_User REFERENCES dbo.Users(UserId),
    CreatedAt      DATETIME2(0)  NOT NULL CONSTRAINT DF_Quotas_Created DEFAULT SYSDATETIME(),
    UpdatedAt      DATETIME2(0)  NULL,
    CONSTRAINT CK_Quotas_Value  CHECK (QuotaValue>0),
    CONSTRAINT CK_Quotas_Period CHECK (PeriodType IN ('HOUR','DAY','MONTH')),
    CONSTRAINT CK_Quotas_Warn   CHECK (WarningPercent>0 AND WarningPercent<100),
    CONSTRAINT CK_Quotas_Dates  CHECK (EffectiveTo IS NULL OR EffectiveTo>=EffectiveFrom),
    CONSTRAINT CK_Quotas_Time   CHECK (TimeTo>TimeFrom),
    CONSTRAINT CK_Quotas_Scope  CHECK (RoomId IS NULL OR FloorId IS NOT NULL)
);
GO
CREATE OR ALTER VIEW dbo.vw_QuotaDetail AS
SELECT q.QuotaId,q.QuotaCode,q.BuildingId,b.BuildingName,q.FloorId,f.FloorName,q.RoomId,r.RoomName,
       CASE WHEN q.RoomId IS NOT NULL THEN N'Phòng' WHEN q.FloorId IS NOT NULL THEN N'Tầng' ELSE N'Tòa nhà' END AS ScopeType,
       COALESCE(r.RoomName,f.FloorName,b.BuildingName) AS AreaName,
       q.EnergyTypeId,e.Name AS EnergyName,e.Unit,q.PeriodType,q.QuotaValue,q.WarningPercent,
       q.EffectiveFrom,q.EffectiveTo,q.TimeFrom,q.TimeTo,q.IsActive,q.Note
FROM dbo.Quotas q
JOIN dbo.Buildings b ON b.BuildingId=q.BuildingId
JOIN dbo.EnergyTypes e ON e.EnergyTypeId=q.EnergyTypeId
LEFT JOIN dbo.Floors f ON f.FloorId=q.FloorId
LEFT JOIN dbo.Rooms r ON r.RoomId=q.RoomId;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Quota_Save
    @QuotaId INT=NULL,@QuotaCode VARCHAR(20),@BuildingId INT,@FloorId INT=NULL,@RoomId INT=NULL,@EnergyTypeId INT,
    @PeriodType VARCHAR(5),@QuotaValue DECIMAL(18,3),@WarningPercent DECIMAL(5,2)=80,
    @EffectiveFrom DATE,@EffectiveTo DATE=NULL,@TimeFrom TIME(0)='00:00:00',@TimeTo TIME(0)='23:59:59',
    @IsActive BIT=1,@Note NVARCHAR(200)=NULL,@UserId INT=NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @QuotaCode=UPPER(LTRIM(RTRIM(@QuotaCode)));
    IF ISNULL(@QuotaCode,'')='' THROW 50401,N'Mã định mức là bắt buộc',1;
    IF @QuotaValue IS NULL OR @QuotaValue<=0 THROW 50402,N'Giá trị định mức phải lớn hơn 0',1;
    IF @PeriodType NOT IN ('HOUR','DAY','MONTH') THROW 50403,N'Chu kỳ định mức không hợp lệ',1;
    IF @WarningPercent<=0 OR @WarningPercent>=100 THROW 50404,N'Ngưỡng cảnh báo vàng phải nằm trong khoảng (0, 100) %',1;
    IF @EffectiveTo IS NOT NULL AND @EffectiveTo<@EffectiveFrom THROW 50405,N'Ngày kết thúc phải sau ngày bắt đầu áp dụng',1;
    IF @TimeTo<=@TimeFrom THROW 50406,N'Giờ kết thúc phải sau giờ bắt đầu',1;
    IF @RoomId IS NOT NULL AND @FloorId IS NULL THROW 50407,N'Chọn phòng thì phải chọn tầng',1;
    IF @FloorId IS NOT NULL AND NOT EXISTS(SELECT 1 FROM dbo.Floors WHERE FloorId=@FloorId AND BuildingId=@BuildingId)
        THROW 50408,N'Tầng không thuộc tòa nhà đã chọn',1;
    IF @RoomId IS NOT NULL AND NOT EXISTS(SELECT 1 FROM dbo.Rooms WHERE RoomId=@RoomId AND FloorId=@FloorId)
        THROW 50409,N'Phòng không thuộc tầng đã chọn',1;
    IF EXISTS(SELECT 1 FROM dbo.Quotas WHERE QuotaCode=@QuotaCode AND QuotaId<>ISNULL(@QuotaId,0)) THROW 50410,N'Mã định mức đã tồn tại',1;
    IF @IsActive=1 AND EXISTS(
        SELECT 1 FROM dbo.Quotas q
        WHERE q.QuotaId<>ISNULL(@QuotaId,0) AND q.IsActive=1 AND q.EnergyTypeId=@EnergyTypeId AND q.PeriodType=@PeriodType
          AND q.BuildingId=@BuildingId AND ISNULL(q.FloorId,0)=ISNULL(@FloorId,0) AND ISNULL(q.RoomId,0)=ISNULL(@RoomId,0)
          AND q.EffectiveFrom<=ISNULL(@EffectiveTo,'9999-12-31') AND ISNULL(q.EffectiveTo,'9999-12-31')>=@EffectiveFrom
          AND q.TimeFrom<=@TimeTo AND q.TimeTo>=@TimeFrom)
        THROW 50411,N'Khung thời gian định mức bị trùng lặp',1;
    IF @QuotaId IS NULL
    BEGIN
        INSERT dbo.Quotas(QuotaCode,BuildingId,FloorId,RoomId,EnergyTypeId,PeriodType,QuotaValue,WarningPercent,EffectiveFrom,EffectiveTo,TimeFrom,TimeTo,IsActive,Note,CreatedBy)
        VALUES(@QuotaCode,@BuildingId,@FloorId,@RoomId,@EnergyTypeId,@PeriodType,@QuotaValue,@WarningPercent,@EffectiveFrom,@EffectiveTo,@TimeFrom,@TimeTo,@IsActive,@Note,@UserId);
        SELECT SCOPE_IDENTITY() AS QuotaId;
    END
    ELSE
    BEGIN   -- mã định mức bị khóa khi sửa (không cập nhật QuotaCode)
        UPDATE dbo.Quotas SET BuildingId=@BuildingId,FloorId=@FloorId,RoomId=@RoomId,EnergyTypeId=@EnergyTypeId,PeriodType=@PeriodType,
               QuotaValue=@QuotaValue,WarningPercent=@WarningPercent,EffectiveFrom=@EffectiveFrom,EffectiveTo=@EffectiveTo,
               TimeFrom=@TimeFrom,TimeTo=@TimeTo,IsActive=@IsActive,Note=@Note,UpdatedAt=SYSDATETIME()
         WHERE QuotaId=@QuotaId;
        SELECT @QuotaId AS QuotaId;
    END
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Quota_List @BuildingId INT=NULL,@FloorId INT=NULL,@EnergyTypeId INT=NULL,@ActiveOnly BIT=0
AS BEGIN SET NOCOUNT ON;
    SELECT * FROM dbo.vw_QuotaDetail
    WHERE (@BuildingId IS NULL OR BuildingId=@BuildingId) AND (@FloorId IS NULL OR FloorId=@FloorId)
      AND (@EnergyTypeId IS NULL OR EnergyTypeId=@EnergyTypeId) AND (@ActiveOnly=0 OR IsActive=1)
    ORDER BY BuildingName,FloorName,QuotaCode; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Quota_SetActive @QuotaId INT,@IsActive BIT
AS
BEGIN
    SET NOCOUNT ON;
    IF @IsActive=1 AND EXISTS(
        SELECT 1 FROM dbo.Quotas a JOIN dbo.Quotas q ON q.QuotaId<>a.QuotaId AND q.IsActive=1 AND q.EnergyTypeId=a.EnergyTypeId AND q.PeriodType=a.PeriodType
          AND q.BuildingId=a.BuildingId AND ISNULL(q.FloorId,0)=ISNULL(a.FloorId,0) AND ISNULL(q.RoomId,0)=ISNULL(a.RoomId,0)
          AND q.EffectiveFrom<=ISNULL(a.EffectiveTo,'9999-12-31') AND ISNULL(q.EffectiveTo,'9999-12-31')>=a.EffectiveFrom
          AND q.TimeFrom<=a.TimeTo AND q.TimeTo>=a.TimeFrom
        WHERE a.QuotaId=@QuotaId)
        THROW 50411,N'Khung thời gian định mức bị trùng lặp',1;
    UPDATE dbo.Quotas SET IsActive=@IsActive,UpdatedAt=SYSDATETIME() WHERE QuotaId=@QuotaId;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Quota_Delete @QuotaId INT
AS BEGIN SET NOCOUNT ON;
    BEGIN TRY DELETE dbo.Quotas WHERE QuotaId=@QuotaId; END TRY
    BEGIN CATCH IF ERROR_NUMBER()=547 THROW 50412,N'Định mức đã phát sinh cảnh báo, chỉ có thể ngưng áp dụng',1; THROW; END CATCH
END
GO
/* =====================================================================
   UC04 - GIÁM SÁT VÀ CẢNH BÁO VƯỢT ĐỊNH MỨC
   Phân rã:
     04.1 Tính tiêu thụ thực tế theo chu kỳ (chỉ dữ liệu sạch, BR08) -> fn_QuotaUsage
     04.2 So sánh với định mức                                        -> usp_Monitor_Scan
     04.3 Tạo cảnh báo VÀNG (>= ngưỡng cảnh báo) / ĐỎ (>= 100%)        -> QuotaAlerts
     04.4 Gửi email cảnh báo cho Quản lý năng lượng                   -> EmailOutbox (include)
     04.5 Xem trạng thái hiện thời / xác nhận xử lý cảnh báo          -> usp_Monitor_Status, usp_Alert_SetStatus
   ===================================================================== */
USE EnergyPortalDB;
GO
IF OBJECT_ID(N'dbo.QuotaAlerts', N'U') IS NULL
CREATE TABLE dbo.QuotaAlerts(
    AlertId      BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_QuotaAlerts PRIMARY KEY,
    QuotaId      INT           NOT NULL CONSTRAINT FK_Alerts_Quota REFERENCES dbo.Quotas(QuotaId),
    PeriodType   VARCHAR(5)    NOT NULL,
    PeriodStart  DATETIME2(0)  NOT NULL,
    ActualValue  DECIMAL(18,3) NOT NULL,
    QuotaValue   DECIMAL(18,3) NOT NULL,
    UsagePercent DECIMAL(9,2)  NOT NULL,
    Severity     VARCHAR(6)    NOT NULL,
    Status       VARCHAR(12)   NOT NULL CONSTRAINT DF_Alerts_Status DEFAULT 'NEW',
    CreatedAt    DATETIME2(0)  NOT NULL CONSTRAINT DF_Alerts_Created DEFAULT SYSDATETIME(),
    UpdatedAt    DATETIME2(0)  NULL,
    HandledBy    INT           NULL CONSTRAINT FK_Alerts_User REFERENCES dbo.Users(UserId),
    HandledAt    DATETIME2(0)  NULL,
    Note         NVARCHAR(300) NULL,
    CONSTRAINT UQ_Alerts UNIQUE(QuotaId,PeriodType,PeriodStart),
    CONSTRAINT CK_Alerts_Sev CHECK (Severity IN ('YELLOW','RED')),
    CONSTRAINT CK_Alerts_Status CHECK (Status IN ('NEW','ACKNOWLEDGED','RESOLVED'))
);
GO
/* 04.1 Tiêu thụ thực tế theo chu kỳ của một định mức: cộng các giờ nằm trong khung giờ & hiệu lực của định mức */
CREATE OR ALTER FUNCTION dbo.fn_QuotaUsage(@QuotaId INT,@From DATETIME2(0),@To DATETIME2(0))
RETURNS TABLE AS RETURN
SELECT CASE q.PeriodType
            WHEN 'HOUR' THEN a.PeriodStart
            WHEN 'DAY'  THEN CAST(CAST(a.PeriodStart AS DATE) AS DATETIME2(0))
            ELSE CAST(DATEFROMPARTS(YEAR(a.PeriodStart),MONTH(a.PeriodStart),1) AS DATETIME2(0)) END AS PeriodStart,
       SUM(a.TotalValue) AS ActualValue
FROM dbo.Quotas q
CROSS APPLY dbo.fn_MetersInScope(q.BuildingId,q.FloorId,q.RoomId,q.EnergyTypeId) s
JOIN dbo.EnergyAggregates a ON a.MeterId=s.MeterId AND a.PeriodType='HOUR'
WHERE q.QuotaId=@QuotaId AND a.PeriodStart>=@From AND a.PeriodStart<@To
  AND CAST(a.PeriodStart AS DATE)>=q.EffectiveFrom AND CAST(a.PeriodStart AS DATE)<=ISNULL(q.EffectiveTo,'9999-12-31')
  AND CAST(a.PeriodStart AS TIME(0))>=q.TimeFrom AND CAST(a.PeriodStart AS TIME(0))<=q.TimeTo
GROUP BY CASE q.PeriodType
            WHEN 'HOUR' THEN a.PeriodStart
            WHEN 'DAY'  THEN CAST(CAST(a.PeriodStart AS DATE) AS DATETIME2(0))
            ELSE CAST(DATEFROMPARTS(YEAR(a.PeriodStart),MONTH(a.PeriodStart),1) AS DATETIME2(0)) END;
GO
/* 04.2-04.4 Tiến trình giám sát (chạy định kỳ hoặc bấm "Quét ngay") */
CREATE OR ALTER PROCEDURE dbo.usp_Monitor_Scan @AsOf DATETIME2(0)=NULL,@LookbackDays INT=3
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @own BIT=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
    BEGIN TRY
        SET @AsOf=ISNULL(@AsOf,SYSDATETIME());
        CREATE TABLE #u(QuotaId INT,PeriodType VARCHAR(5),PeriodStart DATETIME2(0),Actual DECIMAL(18,3),QuotaValue DECIMAL(18,3),
                        WarnPct DECIMAL(5,2),Pct DECIMAL(9,2),Severity VARCHAR(6));
        INSERT #u(QuotaId,PeriodType,PeriodStart,Actual,QuotaValue,WarnPct)
        SELECT q.QuotaId,q.PeriodType,u.PeriodStart,u.ActualValue,q.QuotaValue,q.WarningPercent
        FROM dbo.Quotas q
        CROSS APPLY dbo.fn_QuotaUsage(q.QuotaId,
              CASE q.PeriodType WHEN 'MONTH' THEN CAST(DATEFROMPARTS(YEAR(@AsOf),MONTH(@AsOf),1) AS DATETIME2(0))
                                ELSE DATEADD(DAY,-@LookbackDays,CAST(CAST(@AsOf AS DATE) AS DATETIME2(0))) END,
              DATEADD(HOUR,1,@AsOf)) u
        WHERE q.IsActive=1;
        UPDATE #u SET Pct=CAST(Actual*100.0/QuotaValue AS DECIMAL(9,2));
        UPDATE #u SET Severity=CASE WHEN Pct>=100 THEN 'RED' WHEN Pct>=WarnPct THEN 'YELLOW' END;
        DELETE #u WHERE Severity IS NULL;

        DECLARE @chg TABLE(AlertId BIGINT,Severity VARCHAR(6),Kind VARCHAR(8));
        IF @own=1 BEGIN TRAN;
        -- nâng mức cảnh báo (vàng -> đỏ) hoặc cập nhật số liệu
        UPDATE a SET ActualValue=u.Actual,UsagePercent=u.Pct,
                     Status=CASE WHEN a.Severity='YELLOW' AND u.Severity='RED' THEN 'NEW' ELSE a.Status END,
                     Severity=u.Severity,UpdatedAt=SYSDATETIME()
        OUTPUT inserted.AlertId,inserted.Severity,CASE WHEN deleted.Severity<>inserted.Severity THEN 'UPGRADE' ELSE 'REFRESH' END INTO @chg
        FROM dbo.QuotaAlerts a JOIN #u u ON u.QuotaId=a.QuotaId AND u.PeriodType=a.PeriodType AND u.PeriodStart=a.PeriodStart
        WHERE a.Status<>'RESOLVED' AND (a.ActualValue<>u.Actual OR a.Severity<>u.Severity);
        INSERT dbo.QuotaAlerts(QuotaId,PeriodType,PeriodStart,ActualValue,QuotaValue,UsagePercent,Severity)
        OUTPUT inserted.AlertId,inserted.Severity,'NEW' INTO @chg
        SELECT u.QuotaId,u.PeriodType,u.PeriodStart,u.Actual,u.QuotaValue,u.Pct,u.Severity
        FROM #u u WHERE NOT EXISTS(SELECT 1 FROM dbo.QuotaAlerts a WHERE a.QuotaId=u.QuotaId AND a.PeriodType=u.PeriodType AND a.PeriodStart=u.PeriodStart);

        -- 04.4 email cho Quản lý năng lượng (chỉ cảnh báo mới hoặc vừa nâng mức)
        INSERT dbo.EmailOutbox(ToEmail,ToName,Subject,Body,EmailType)
        SELECT us.Email,us.FullName,
               N'[EVN-03] Cảnh báo '+CASE c.Severity WHEN 'RED' THEN N'ĐỎ' ELSE N'VÀNG' END+N' vượt định mức '+d.QuotaCode,
               N'Khu vực: '+d.AreaName+N' ('+d.EnergyName+N')'+CHAR(13)+CHAR(10)+
               N'Chu kỳ: '+a.PeriodType+N' bắt đầu '+CONVERT(NVARCHAR(20),a.PeriodStart,120)+CHAR(13)+CHAR(10)+
               N'Thực tế: '+CAST(a.ActualValue AS NVARCHAR(30))+N' '+d.Unit+N' / Định mức: '+CAST(a.QuotaValue AS NVARCHAR(30))+N' '+d.Unit+
               N' ('+CAST(a.UsagePercent AS NVARCHAR(20))+N'%)',
               'QUOTA_ALERT'
        FROM @chg c JOIN dbo.QuotaAlerts a ON a.AlertId=c.AlertId JOIN dbo.vw_QuotaDetail d ON d.QuotaId=a.QuotaId
        CROSS JOIN (SELECT u.Email,u.FullName FROM dbo.Users u JOIN dbo.Roles r ON r.RoleId=u.RoleId
                    WHERE r.RoleCode='ENERGY_MANAGER' AND u.Status='ACTIVE') us
        WHERE c.Kind IN ('NEW','UPGRADE');
        IF @own=1 COMMIT;

        SELECT SUM(CASE WHEN Kind='NEW' AND Severity='RED' THEN 1 ELSE 0 END) AS NewRed,
               SUM(CASE WHEN Kind='NEW' AND Severity='YELLOW' THEN 1 ELSE 0 END) AS NewYellow,
               SUM(CASE WHEN Kind IN ('UPGRADE','REFRESH') THEN 1 ELSE 0 END) AS Updated FROM @chg;
    END TRY
    BEGIN CATCH
        IF @own=1 AND @@TRANCOUNT>0 ROLLBACK; THROW;
    END CATCH
END
GO
/* Trạng thái hiện thời mỗi định mức (đổi màu Đỏ/Vàng/Xanh trên màn hình giám sát) */
CREATE OR ALTER PROCEDURE dbo.usp_Monitor_Status @BuildingId INT=NULL,@EnergyTypeId INT=NULL,@AsOf DATETIME2(0)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @AsOf=ISNULL(@AsOf,SYSDATETIME());
    SELECT d.QuotaId,d.QuotaCode,d.AreaName,d.ScopeType,d.EnergyName,d.Unit,d.PeriodType,d.QuotaValue,d.WarningPercent,
           u.PeriodStart,ISNULL(u.ActualValue,0) AS ActualValue,
           CAST(ISNULL(u.ActualValue,0)*100.0/d.QuotaValue AS DECIMAL(9,2)) AS UsagePercent,
           CASE WHEN u.ActualValue IS NULL THEN 'NODATA'
                WHEN u.ActualValue>=d.QuotaValue THEN 'RED'
                WHEN u.ActualValue>=d.QuotaValue*d.WarningPercent/100 THEN 'YELLOW' ELSE 'GREEN' END AS State
    FROM dbo.vw_QuotaDetail d
    OUTER APPLY (SELECT TOP 1 x.PeriodStart,x.ActualValue
                 FROM dbo.fn_QuotaUsage(d.QuotaId,
                      CASE d.PeriodType WHEN 'MONTH' THEN CAST(DATEFROMPARTS(YEAR(@AsOf),MONTH(@AsOf),1) AS DATETIME2(0))
                                        ELSE DATEADD(DAY,-1,CAST(CAST(@AsOf AS DATE) AS DATETIME2(0))) END,
                      DATEADD(HOUR,1,@AsOf)) x
                 ORDER BY x.PeriodStart DESC) u
    WHERE d.IsActive=1 AND (@BuildingId IS NULL OR d.BuildingId=@BuildingId) AND (@EnergyTypeId IS NULL OR d.EnergyTypeId=@EnergyTypeId)
    ORDER BY CASE WHEN u.ActualValue>=d.QuotaValue THEN 0 WHEN u.ActualValue>=d.QuotaValue*d.WarningPercent/100 THEN 1 ELSE 2 END,d.AreaName;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Alert_List
    @Status VARCHAR(12)=NULL,@Severity VARCHAR(6)=NULL,@From DATETIME2(0)=NULL,@To DATETIME2(0)=NULL,@Top INT=1000
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Top) a.AlertId,d.QuotaCode,d.AreaName,d.EnergyName,d.Unit,a.PeriodType,a.PeriodStart,a.ActualValue,a.QuotaValue,
           a.UsagePercent,a.Severity,a.Status,a.CreatedAt,u.FullName AS HandledByName,a.HandledAt,a.Note
    FROM dbo.QuotaAlerts a JOIN dbo.vw_QuotaDetail d ON d.QuotaId=a.QuotaId LEFT JOIN dbo.Users u ON u.UserId=a.HandledBy
    WHERE (@Status IS NULL OR a.Status=@Status) AND (@Severity IS NULL OR a.Severity=@Severity)
      AND (@From IS NULL OR a.PeriodStart>=@From) AND (@To IS NULL OR a.PeriodStart<=@To)
    ORDER BY a.CreatedAt DESC,a.AlertId DESC;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Alert_SetStatus @AlertId BIGINT,@Status VARCHAR(12),@UserId INT,@Note NVARCHAR(300)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @Status NOT IN ('ACKNOWLEDGED','RESOLVED') THROW 50420,N'Trạng thái xử lý không hợp lệ',1;
    IF @Status='RESOLVED' AND ISNULL(@Note,N'')=N'' THROW 50421,N'Vui lòng nhập ghi chú biện pháp xử lý khi đóng cảnh báo',1;
    UPDATE dbo.QuotaAlerts SET Status=@Status,HandledBy=@UserId,HandledAt=SYSDATETIME(),Note=@Note,UpdatedAt=SYSDATETIME() WHERE AlertId=@AlertId;
    IF @@ROWCOUNT=0 THROW 50422,N'Cảnh báo không tồn tại',1;
END
GO
/* =====================================================================
   UC05 - PHÂN TÍCH VÀ PHÁT HIỆN BẤT THƯỜNG DỮ LIỆU (Data Anomaly)
   Phân rã:
     05.1 Quét kiểm tra chất lượng dữ liệu (Data Quality Scan Job) «include» -> usp_DQ_Scan
     05.2 Gắn nhãn lỗi kỹ thuật: NEGATIVE (âm) / MISSING (khuyết) / SPIKE (nhảy vọt) «include» -> DataAnomalies
     05.3 Cảnh báo công tơ mất tín hiệu kéo dài «extend»                      -> NO_SIGNAL trong usp_DQ_Scan
     05.4 Thông báo cho Kỹ thuật viên                                          -> EmailOutbox (DATA_ANOMALY)
     05.5 Xem danh sách chờ xử lý / lịch sử quét                               -> usp_DQ_List, usp_DQ_ScanRuns_List
   BR05: bảng DataAnomalies TÁCH BIỆT với ConsumptionAnomalies (UC06).
   Quy tắc: giá trị < 0 | chỗ khuyết trong chuỗi | > MaxValuePerInterval | > SPIKE_FACTOR x TB 24 chu kỳ trước.
   ===================================================================== */
USE EnergyPortalDB;
GO
IF OBJECT_ID(N'dbo.DQScanRuns', N'U') IS NULL
CREATE TABLE dbo.DQScanRuns(
    ScanId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DQScanRuns PRIMARY KEY,
    StartedAt    DATETIME2(0) NOT NULL CONSTRAINT DF_DQScan_Start DEFAULT SYSDATETIME(),
    FinishedAt   DATETIME2(0) NULL,
    Mode         VARCHAR(10)  NOT NULL,
    TriggeredBy  INT NULL CONSTRAINT FK_DQScan_User REFERENCES dbo.Users(UserId),
    MeterId      INT NULL,
    RangeFrom    DATETIME2(0) NULL,
    RangeTo      DATETIME2(0) NULL,
    ScannedCount INT NOT NULL CONSTRAINT DF_DQScan_Cnt DEFAULT 0,
    AnomalyCount INT NOT NULL CONSTRAINT DF_DQScan_An DEFAULT 0
);
GO
IF OBJECT_ID(N'dbo.DataAnomalies', N'U') IS NULL
CREATE TABLE dbo.DataAnomalies(
    AnomalyId   BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DataAnomalies PRIMARY KEY,
    RawId       BIGINT NULL CONSTRAINT FK_DA_Raw REFERENCES dbo.RawTelemetry(RawId),
    MeterId     INT    NOT NULL CONSTRAINT FK_DA_Meter REFERENCES dbo.Meters(MeterId),
    AnomalyType VARCHAR(10)   NOT NULL,
    ErrorCode   VARCHAR(10)   NOT NULL,
    Description NVARCHAR(300) NULL,
    DetectedAt  DATETIME2(0)  NOT NULL CONSTRAINT DF_DA_Detected DEFAULT SYSDATETIME(),
    Status      VARCHAR(10)   NOT NULL CONSTRAINT DF_DA_Status DEFAULT 'OPEN',
    ScanId      INT NULL CONSTRAINT FK_DA_Scan REFERENCES dbo.DQScanRuns(ScanId),
    ResolvedAt  DATETIME2(0)  NULL,
    ResolvedBy  INT NULL CONSTRAINT FK_DA_User REFERENCES dbo.Users(UserId),
    TransformId BIGINT NULL,                                     -- FK bổ sung ở UC07
    Note        NVARCHAR(300) NULL,
    CONSTRAINT CK_DA_Type   CHECK (AnomalyType IN ('NEGATIVE','MISSING','SPIKE','NO_SIGNAL')),
    CONSTRAINT CK_DA_Status CHECK (Status IN ('OPEN','RESOLVED','IGNORED'))
);
GO
CREATE UNIQUE INDEX UX_DA_OpenRaw ON dbo.DataAnomalies(RawId,AnomalyType) WHERE Status='OPEN' AND RawId IS NOT NULL;
CREATE INDEX IX_DA_StatusMeter ON dbo.DataAnomalies(Status,MeterId);
GO

CREATE OR ALTER PROCEDURE dbo.usp_DQ_Scan
    @MeterId INT=NULL,@From DATETIME2(0)=NULL,@To DATETIME2(0)=NULL,@UserId INT=NULL,@Mode VARCHAR(10)='MANUAL',
    @Rescan BIT=0,@Aggregate BIT=1,@Quiet BIT=0,@ScannedCount INT=0 OUTPUT,@AnomalyCount INT=0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @own BIT=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
    BEGIN TRY
        SET @ScannedCount=0; SET @AnomalyCount=0;
        IF @own=1 BEGIN TRAN;

        IF @Rescan=1 AND @From IS NOT NULL AND @To IS NOT NULL      -- quét lại dữ liệu đã đạt trước đó
            UPDATE dbo.RawTelemetry SET QualityStatus='PENDING'
             WHERE QualityStatus='VALID' AND ReadingValue IS NOT NULL AND ReadingTime BETWEEN @From AND @To AND (@MeterId IS NULL OR MeterId=@MeterId);

        IF @From IS NULL OR @To IS NULL
            SELECT @From=ISNULL(@From,MIN(ReadingTime)),@To=ISNULL(@To,MAX(ReadingTime))
            FROM dbo.RawTelemetry WHERE QualityStatus='PENDING' AND (@MeterId IS NULL OR MeterId=@MeterId);

        INSERT dbo.DQScanRuns(Mode,TriggeredBy,MeterId,RangeFrom,RangeTo) VALUES(@Mode,@UserId,@MeterId,@From,@To);
        DECLARE @ScanId INT=SCOPE_IDENTITY();
        DECLARE @factor DECIMAL(18,4)=dbo.fn_SettingNum('SPIKE_FACTOR');
        DECLARE @n INT;

        IF @From IS NOT NULL AND @To IS NOT NULL
        BEGIN
            /* A. Phát hiện khuyết: tạo bản ghi giữ chỗ (SYSTEM) cho các mốc thiếu giữa điểm đầu và cuối của chuỗi */
            ;WITH nums AS (
                SELECT TOP (20000) CAST(ROW_NUMBER() OVER(ORDER BY (SELECT NULL))-1 AS INT) AS n
                FROM sys.all_columns a CROSS JOIN sys.all_columns b),
            rng AS (
                SELECT r.MeterId,m.IntervalMinutes AS iv,MIN(r.ReadingTime) AS mn,MAX(r.ReadingTime) AS mx
                FROM dbo.RawTelemetry r JOIN dbo.Meters m ON m.MeterId=r.MeterId
                WHERE r.ReadingTime BETWEEN @From AND @To AND (@MeterId IS NULL OR r.MeterId=@MeterId)
                GROUP BY r.MeterId,m.IntervalMinutes)
            INSERT dbo.RawTelemetry(MeterId,ReadingTime,ReadingValue,SourceType,QualityStatus)
            SELECT rng.MeterId,DATEADD(MINUTE,nums.n*rng.iv,rng.mn),NULL,'SYSTEM','PENDING'
            FROM rng JOIN nums ON DATEADD(MINUTE,nums.n*rng.iv,rng.mn)<=rng.mx
            WHERE NOT EXISTS(SELECT 1 FROM dbo.RawTelemetry x WHERE x.MeterId=rng.MeterId AND x.ReadingTime=DATEADD(MINUTE,nums.n*rng.iv,rng.mn));

            /* B. Áp dụng quy tắc kiểm soát dữ liệu thô */
            SELECT r.RawId,r.MeterId,r.ReadingTime,r.ReadingValue,r.QualityStatus,m.MaxValuePerInterval AS Mx,
                   AVG(CASE WHEN r.ReadingValue>=0 AND (m.MaxValuePerInterval IS NULL OR r.ReadingValue<=m.MaxValuePerInterval)
                             AND r.QualityStatus<>'ANOMALY' THEN r.ReadingValue END)
                       OVER(PARTITION BY r.MeterId ORDER BY r.ReadingTime ROWS BETWEEN 24 PRECEDING AND 1 PRECEDING) AS PrevAvg
            INTO #dq_src
            FROM dbo.RawTelemetry r JOIN dbo.Meters m ON m.MeterId=r.MeterId
            WHERE r.ReadingTime>=DATEADD(HOUR,-48,@From) AND r.ReadingTime<=@To AND (@MeterId IS NULL OR r.MeterId=@MeterId);

            SELECT @ScannedCount=COUNT(*) FROM #dq_src WHERE QualityStatus='PENDING' AND ReadingTime BETWEEN @From AND @To;

            SELECT RawId,MeterId,
                   CASE WHEN ReadingValue IS NULL THEN 'MISSING' WHEN ReadingValue<0 THEN 'NEGATIVE' ELSE 'SPIKE' END AS Typ,
                   CASE WHEN ReadingValue IS NULL THEN 'DQ-002' WHEN ReadingValue<0 THEN 'DQ-001' ELSE 'DQ-003' END AS Code,
                   CASE WHEN ReadingValue IS NULL THEN N'Khuyết dữ liệu tại mốc '+CONVERT(NVARCHAR(20),ReadingTime,120)
                        WHEN ReadingValue<0 THEN N'Chỉ số âm ('+CAST(ReadingValue AS NVARCHAR(30))+N') tại '+CONVERT(NVARCHAR(20),ReadingTime,120)
                        ELSE N'Nhảy vọt phi lý ('+CAST(ReadingValue AS NVARCHAR(30))+N') tại '+CONVERT(NVARCHAR(20),ReadingTime,120) END AS Descr
            INTO #dq_flag
            FROM #dq_src
            WHERE QualityStatus='PENDING' AND ReadingTime BETWEEN @From AND @To
              AND (ReadingValue IS NULL OR ReadingValue<0 OR (Mx IS NOT NULL AND ReadingValue>Mx) OR (PrevAvg>0 AND ReadingValue>@factor*PrevAvg));

            INSERT dbo.DataAnomalies(RawId,MeterId,AnomalyType,ErrorCode,Description,ScanId)
            SELECT f.RawId,f.MeterId,f.Typ,f.Code,f.Descr,@ScanId FROM #dq_flag f
            WHERE NOT EXISTS(SELECT 1 FROM dbo.DataAnomalies d WHERE d.RawId=f.RawId AND d.AnomalyType=f.Typ AND d.Status='OPEN');
            SELECT @AnomalyCount=COUNT(*) FROM #dq_flag;

            UPDATE r SET QualityStatus='ANOMALY' FROM dbo.RawTelemetry r JOIN #dq_flag f ON f.RawId=r.RawId;
            UPDATE dbo.RawTelemetry SET QualityStatus='VALID'
             WHERE QualityStatus='PENDING' AND ReadingTime BETWEEN @From AND @To AND (@MeterId IS NULL OR MeterId=@MeterId);

            IF @Aggregate=1
            BEGIN
                DECLARE @m INT,@a DATETIME2(0),@b DATETIME2(0);
                DECLARE c CURSOR LOCAL FAST_FORWARD FOR
                    SELECT MeterId,MIN(ReadingTime),MAX(ReadingTime) FROM #dq_src WHERE ReadingTime>=@From GROUP BY MeterId;
                OPEN c; FETCH NEXT FROM c INTO @m,@a,@b;
                WHILE @@FETCH_STATUS=0
                BEGIN EXEC dbo.usp_Aggregate_Meter @m,@a,@b; FETCH NEXT FROM c INTO @m,@a,@b; END
                CLOSE c; DEALLOCATE c;
            END
        END

        /* C. «extend» Công tơ mất tín hiệu kéo dài */
        DECLARE @nsh INT=CAST(dbo.fn_SettingNum('NO_SIGNAL_HOURS') AS INT),@now DATETIME2(0)=SYSDATETIME();
        INSERT dbo.DataAnomalies(RawId,MeterId,AnomalyType,ErrorCode,Description,ScanId)
        SELECT NULL,m.MeterId,'NO_SIGNAL','DQ-004',N'Công tơ '+m.MeterCode+N' mất tín hiệu từ '+CONVERT(NVARCHAR(20),m.LastReadingAt,120),@ScanId
        FROM dbo.Meters m
        WHERE m.Status='ACTIVE' AND m.LastReadingAt IS NOT NULL AND m.LastReadingAt<DATEADD(HOUR,-@nsh,@now) AND (@MeterId IS NULL OR m.MeterId=@MeterId)
          AND NOT EXISTS(SELECT 1 FROM dbo.DataAnomalies d WHERE d.MeterId=m.MeterId AND d.AnomalyType='NO_SIGNAL' AND d.Status='OPEN');
        SET @n=@@ROWCOUNT; SET @AnomalyCount+=@n;
        UPDATE d SET Status='RESOLVED',ResolvedAt=@now,Note=N'Công tơ đã có tín hiệu trở lại'
        FROM dbo.DataAnomalies d JOIN dbo.Meters m ON m.MeterId=d.MeterId
        WHERE d.AnomalyType='NO_SIGNAL' AND d.Status='OPEN' AND m.LastReadingAt>=DATEADD(HOUR,-@nsh,@now);

        /* D. Thông báo Kỹ thuật viên */
        IF @AnomalyCount>0
        BEGIN
            DECLARE @body NVARCHAR(MAX)=N'Lần quét #'+CAST(@ScanId AS NVARCHAR(10))+N' phát hiện '+CAST(@AnomalyCount AS NVARCHAR(10))+
                N' bất thường dữ liệu kỹ thuật (âm / khuyết / nhảy vọt / mất tín hiệu). Vào chức năng "Bất thường dữ liệu" để xử lý.';
            EXEC dbo.usp_Email_QueueForRole 'TECHNICIAN',N'[EVN-03] Phát hiện bất thường dữ liệu',@body,'DATA_ANOMALY';
        END
        UPDATE dbo.DQScanRuns SET FinishedAt=SYSDATETIME(),ScannedCount=@ScannedCount,AnomalyCount=@AnomalyCount WHERE ScanId=@ScanId;
        DECLARE @mv DECIMAL(18,3)=@AnomalyCount;
        EXEC dbo.usp_Metric_Emit 'dq_anomalies_detected',@mv,'count',@Mode;
        IF @own=1 COMMIT;
        IF @Quiet=0 SELECT @ScanId AS ScanId,@ScannedCount AS ScannedCount,@AnomalyCount AS AnomalyCount;
    END TRY
    BEGIN CATCH
        IF @own=1 AND @@TRANCOUNT>0 ROLLBACK; THROW;
    END CATCH
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_DQ_List
    @Status VARCHAR(10)=NULL,@MeterId INT=NULL,@Type VARCHAR(10)=NULL,@From DATETIME2(0)=NULL,@To DATETIME2(0)=NULL,@Top INT=2000
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Top) d.AnomalyId,d.RawId,m.MeterId,m.MeterCode,d.AnomalyType,d.ErrorCode,d.Description,r.ReadingTime,r.ReadingValue,
           d.DetectedAt,d.Status,u.FullName AS ResolvedByName,d.ResolvedAt,d.Note
    FROM dbo.DataAnomalies d
    JOIN dbo.Meters m ON m.MeterId=d.MeterId
    LEFT JOIN dbo.RawTelemetry r ON r.RawId=d.RawId
    LEFT JOIN dbo.Users u ON u.UserId=d.ResolvedBy
    WHERE (@Status IS NULL OR d.Status=@Status) AND (@MeterId IS NULL OR d.MeterId=@MeterId) AND (@Type IS NULL OR d.AnomalyType=@Type)
      AND (@From IS NULL OR ISNULL(r.ReadingTime,d.DetectedAt)>=@From) AND (@To IS NULL OR ISNULL(r.ReadingTime,d.DetectedAt)<=@To)
    ORDER BY ISNULL(r.ReadingTime,d.DetectedAt) DESC,d.AnomalyId DESC;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_DQ_ScanRuns_List @Top INT=100
AS BEGIN SET NOCOUNT ON;
    SELECT TOP (@Top) s.ScanId,s.StartedAt,s.FinishedAt,s.Mode,u.FullName AS TriggeredByName,m.MeterCode,s.RangeFrom,s.RangeTo,s.ScannedCount,s.AnomalyCount
    FROM dbo.DQScanRuns s LEFT JOIN dbo.Users u ON u.UserId=s.TriggeredBy LEFT JOIN dbo.Meters m ON m.MeterId=s.MeterId ORDER BY s.ScanId DESC; END
GO
/* =====================================================================
   UC06 - PHÂN TÍCH VÀ CẢNH BÁO BẤT THƯỜNG TIÊU THỤ (Consumption Anomaly)
   Phân rã:
     06.1 Tính đường cơ sở Baseline (chỉ dữ liệu sạch, BR08)   -> usp_Baseline_Compute
     06.2 Quét điểm bất thường: ngoài giờ / quá tải / rò rỉ     -> usp_CA_Scan
     06.3 Đồ thị so sánh thực tế - Baseline - tuần trước        -> usp_CA_Series
     06.4 «extend» Xác nhận hoạt động có kế hoạch để đóng cảnh báo -> usp_CA_SetStatus
     06.5 Thông báo Quản lý năng lượng                          -> EmailOutbox
   Chỉ phân tích khung giờ có dữ liệu ĐẠT CHẤT LƯỢNG (IsComplete = 1) -> tách biệt với UC05 (BR05).
   Điều kiện bất thường: thực tế > TB + Z x Độ lệch chuẩn  VÀ  thực tế > ANOMALY_MIN_RATIO x TB.
   ===================================================================== */
USE EnergyPortalDB;
GO
IF OBJECT_ID(N'dbo.Baselines', N'U') IS NULL
CREATE TABLE dbo.Baselines(
    BaselineId  INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Baselines PRIMARY KEY,
    MeterId     INT          NOT NULL CONSTRAINT FK_Baseline_Meter REFERENCES dbo.Meters(MeterId),
    DayType     VARCHAR(7)   NOT NULL,
    HourOfDay   TINYINT      NOT NULL,
    AvgValue    DECIMAL(18,3) NOT NULL,
    StdDev      DECIMAL(18,3) NOT NULL,
    SampleCount INT          NOT NULL,
    CalcFrom    DATE         NOT NULL,
    CalcTo      DATE         NOT NULL,
    UpdatedAt   DATETIME2(0) NOT NULL CONSTRAINT DF_Baseline_Upd DEFAULT SYSDATETIME(),
    CONSTRAINT UQ_Baseline UNIQUE(MeterId,DayType,HourOfDay),
    CONSTRAINT CK_Baseline_DayType CHECK (DayType IN ('WEEKDAY','WEEKEND')),
    CONSTRAINT CK_Baseline_Hour CHECK (HourOfDay BETWEEN 0 AND 23)
);
GO
IF OBJECT_ID(N'dbo.ConsumptionAnomalies', N'U') IS NULL
CREATE TABLE dbo.ConsumptionAnomalies(
    CAnomalyId   BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ConsAnom PRIMARY KEY,
    MeterId      INT          NOT NULL CONSTRAINT FK_CA_Meter REFERENCES dbo.Meters(MeterId),
    PeriodStart  DATETIME2(0) NOT NULL,
    ActualValue  DECIMAL(18,3) NOT NULL,
    BaselineValue DECIMAL(18,3) NOT NULL,
    StdDev       DECIMAL(18,3) NOT NULL,
    DeviationPercent DECIMAL(9,2) NOT NULL,
    AnomalyType  VARCHAR(10)  NOT NULL,
    Severity     VARCHAR(6)   NOT NULL,
    Status       VARCHAR(10)  NOT NULL CONSTRAINT DF_CA_Status DEFAULT 'NEW',
    Note         NVARCHAR(300) NULL,
    HandledBy    INT NULL CONSTRAINT FK_CA_User REFERENCES dbo.Users(UserId),
    HandledAt    DATETIME2(0) NULL,
    CreatedAt    DATETIME2(0) NOT NULL CONSTRAINT DF_CA_Created DEFAULT SYSDATETIME(),
    CONSTRAINT UQ_CA UNIQUE(MeterId,PeriodStart),
    CONSTRAINT CK_CA_Type CHECK (AnomalyType IN ('OFF_HOURS','OVERLOAD','LEAK')),
    CONSTRAINT CK_CA_Sev  CHECK (Severity IN ('LOW','MEDIUM','HIGH')),
    CONSTRAINT CK_CA_Status CHECK (Status IN ('NEW','CONFIRMED','PLANNED','CLOSED'))
);
GO
/* 06.1 */
CREATE OR ALTER PROCEDURE dbo.usp_Baseline_Compute @MeterId INT=NULL,@From DATE=NULL,@To DATE=NULL,@Quiet BIT=0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @own BIT=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
    BEGIN TRY
        DECLARE @days INT=CAST(dbo.fn_SettingNum('BASELINE_DAYS') AS INT);
        SET @To=ISNULL(@To,DATEADD(DAY,-1,CAST(SYSDATETIME() AS DATE)));
        SET @From=ISNULL(@From,DATEADD(DAY,-(@days-1),@To));
        IF @own=1 BEGIN TRAN;
        DELETE dbo.Baselines WHERE @MeterId IS NULL OR MeterId=@MeterId;
        INSERT dbo.Baselines(MeterId,DayType,HourOfDay,AvgValue,StdDev,SampleCount,CalcFrom,CalcTo)
        SELECT a.MeterId,dbo.fn_DayType(CAST(a.PeriodStart AS DATE)),DATEPART(HOUR,a.PeriodStart),
               AVG(a.TotalValue),ISNULL(STDEV(a.TotalValue),0),COUNT(*),@From,@To
        FROM dbo.EnergyAggregates a
        WHERE a.PeriodType='HOUR' AND a.IsComplete=1 AND a.PeriodStart>=@From AND a.PeriodStart<DATEADD(DAY,1,@To)
          AND (@MeterId IS NULL OR a.MeterId=@MeterId)
          AND NOT EXISTS(SELECT 1 FROM dbo.ConsumptionAnomalies c WHERE c.MeterId=a.MeterId AND c.PeriodStart=a.PeriodStart AND c.Status IN ('NEW','CONFIRMED'))
        GROUP BY a.MeterId,dbo.fn_DayType(CAST(a.PeriodStart AS DATE)),DATEPART(HOUR,a.PeriodStart);
        IF @own=1 COMMIT;
        IF @Quiet=0 SELECT COUNT(*) AS BaselineRows FROM dbo.Baselines WHERE @MeterId IS NULL OR MeterId=@MeterId;
    END TRY
    BEGIN CATCH
        IF @own=1 AND @@TRANCOUNT>0 ROLLBACK; THROW;
    END CATCH
END
GO
/* 06.2 */
CREATE OR ALTER PROCEDURE dbo.usp_CA_Scan @MeterId INT=NULL,@From DATETIME2(0)=NULL,@To DATETIME2(0)=NULL,@UserId INT=NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @own BIT=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
    BEGIN TRY
        SET @To=ISNULL(@To,CAST(DATEADD(HOUR,DATEDIFF(HOUR,'19000101',SYSDATETIME()),'19000101') AS DATETIME2(0)));
        SET @From=ISNULL(@From,DATEADD(DAY,-7,@To));
        IF @To<@From THROW 50601,N'Khoảng thời gian phân tích không hợp lệ',1;
        DECLARE @days INT=CAST(dbo.fn_SettingNum('BASELINE_DAYS') AS INT);
        DECLARE @z DECIMAL(18,4)=dbo.fn_SettingNum('ANOMALY_Z'),@ratio DECIMAL(18,4)=dbo.fn_SettingNum('ANOMALY_MIN_RATIO');
        DECLARE @ws INT=CAST(dbo.fn_SettingNum('WORK_START_HOUR') AS INT),@we INT=CAST(dbo.fn_SettingNum('WORK_END_HOUR') AS INT);
        DECLARE @bTo DATE=DATEADD(DAY,-1,CAST(@From AS DATE)),@bFrom DATE=DATEADD(DAY,-@days,CAST(@From AS DATE));
        IF @own=1 BEGIN TRAN;
        EXEC dbo.usp_Baseline_Compute @MeterId,@bFrom,@bTo,@Quiet=1;     -- đường cơ sở từ dữ liệu sạch TRƯỚC khoảng phân tích

        DECLARE @examined INT=(SELECT COUNT(*) FROM dbo.EnergyAggregates WHERE PeriodType='HOUR' AND IsComplete=1
                               AND PeriodStart>=@From AND PeriodStart<=@To AND (@MeterId IS NULL OR MeterId=@MeterId));
        DECLARE @skipped INT=(SELECT COUNT(*) FROM dbo.EnergyAggregates WHERE PeriodType='HOUR' AND IsComplete=0
                               AND PeriodStart>=@From AND PeriodStart<=@To AND (@MeterId IS NULL OR MeterId=@MeterId));

        INSERT dbo.ConsumptionAnomalies(MeterId,PeriodStart,ActualValue,BaselineValue,StdDev,DeviationPercent,AnomalyType,Severity)
        SELECT x.MeterId,x.PeriodStart,x.TotalValue,x.AvgValue,x.StdDev,x.Dev,x.Typ,
               CASE WHEN x.Dev>=100 THEN 'HIGH' WHEN x.Dev>=50 THEN 'MEDIUM' ELSE 'LOW' END
        FROM (SELECT a.MeterId,a.PeriodStart,a.TotalValue,b.AvgValue,b.StdDev,
                     CAST(CASE WHEN b.AvgValue>0 THEN (a.TotalValue-b.AvgValue)*100.0/b.AvgValue ELSE 100 END AS DECIMAL(9,2)) AS Dev,
                     CASE WHEN DATEPART(HOUR,a.PeriodStart)<@ws OR DATEPART(HOUR,a.PeriodStart)>=@we
                          THEN CASE WHEN e.Code='ELEC' THEN 'OFF_HOURS' ELSE 'LEAK' END ELSE 'OVERLOAD' END AS Typ
              FROM dbo.EnergyAggregates a
              JOIN dbo.Baselines b ON b.MeterId=a.MeterId AND b.DayType=dbo.fn_DayType(CAST(a.PeriodStart AS DATE)) AND b.HourOfDay=DATEPART(HOUR,a.PeriodStart)
              JOIN dbo.Meters m ON m.MeterId=a.MeterId JOIN dbo.EnergyTypes e ON e.EnergyTypeId=m.EnergyTypeId
              WHERE a.PeriodType='HOUR' AND a.IsComplete=1 AND a.PeriodStart>=@From AND a.PeriodStart<=@To
                AND (@MeterId IS NULL OR a.MeterId=@MeterId) AND b.SampleCount>=3 AND a.TotalValue>0
                AND a.TotalValue>b.AvgValue+@z*b.StdDev AND a.TotalValue>b.AvgValue*@ratio) x
        WHERE NOT EXISTS(SELECT 1 FROM dbo.ConsumptionAnomalies c WHERE c.MeterId=x.MeterId AND c.PeriodStart=x.PeriodStart);
        DECLARE @new INT=@@ROWCOUNT;

        IF @new>0
        BEGIN
            DECLARE @body NVARCHAR(MAX)=N'Phát hiện '+CAST(@new AS NVARCHAR(10))+N' khung giờ có tiêu thụ bất thường (ngoài giờ / quá tải / rò rỉ). Vào "Bất thường tiêu thụ" để xem chi tiết.';
            EXEC dbo.usp_Email_QueueForRole 'ENERGY_MANAGER',N'[EVN-03] Cảnh báo bất thường tiêu thụ',@body,'CONSUMPTION';
        END
        IF @own=1 COMMIT;
        SELECT @examined AS HoursExamined,@new AS NewAnomalies,@skipped AS SkippedIncomplete;
    END TRY
    BEGIN CATCH
        IF @own=1 AND @@TRANCOUNT>0 ROLLBACK; THROW;
    END CATCH
END
GO
/* 06.3 */
CREATE OR ALTER PROCEDURE dbo.usp_CA_Series @MeterId INT,@From DATETIME2(0),@To DATETIME2(0)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @z DECIMAL(18,4)=dbo.fn_SettingNum('ANOMALY_Z');
    SELECT a.PeriodStart,a.TotalValue AS ActualValue,a.IsComplete,b.AvgValue AS BaselineValue,
           b.AvgValue+@z*b.StdDev AS UpperBound,p.TotalValue AS PrevWeekValue,
           CASE WHEN c.CAnomalyId IS NULL THEN CAST(0 AS BIT) ELSE CAST(1 AS BIT) END AS IsAnomaly,c.Status AS AnomalyStatus
    FROM dbo.EnergyAggregates a
    LEFT JOIN dbo.Baselines b ON b.MeterId=a.MeterId AND b.DayType=dbo.fn_DayType(CAST(a.PeriodStart AS DATE)) AND b.HourOfDay=DATEPART(HOUR,a.PeriodStart)
    LEFT JOIN dbo.EnergyAggregates p ON p.MeterId=a.MeterId AND p.PeriodType='HOUR' AND p.PeriodStart=DATEADD(DAY,-7,a.PeriodStart) AND p.IsComplete=1
    LEFT JOIN dbo.ConsumptionAnomalies c ON c.MeterId=a.MeterId AND c.PeriodStart=a.PeriodStart
    WHERE a.MeterId=@MeterId AND a.PeriodType='HOUR' AND a.PeriodStart>=@From AND a.PeriodStart<=@To
    ORDER BY a.PeriodStart;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_CA_List
    @Status VARCHAR(10)=NULL,@MeterId INT=NULL,@From DATETIME2(0)=NULL,@To DATETIME2(0)=NULL,@Top INT=1000
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Top) c.CAnomalyId,c.MeterId,m.MeterCode,m.MeterName,c.PeriodStart,c.ActualValue,c.BaselineValue,c.StdDev,c.DeviationPercent,
           c.AnomalyType,c.Severity,c.Status,c.Note,u.FullName AS HandledByName,c.HandledAt,c.CreatedAt
    FROM dbo.ConsumptionAnomalies c JOIN dbo.Meters m ON m.MeterId=c.MeterId LEFT JOIN dbo.Users u ON u.UserId=c.HandledBy
    WHERE (@Status IS NULL OR c.Status=@Status) AND (@MeterId IS NULL OR c.MeterId=@MeterId)
      AND (@From IS NULL OR c.PeriodStart>=@From) AND (@To IS NULL OR c.PeriodStart<=@To)
    ORDER BY c.PeriodStart DESC,c.CAnomalyId DESC;
END
GO
/* 06.4 */
CREATE OR ALTER PROCEDURE dbo.usp_CA_SetStatus @CAnomalyId BIGINT,@Status VARCHAR(10),@UserId INT,@Note NVARCHAR(300)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @Status NOT IN ('CONFIRMED','PLANNED','CLOSED') THROW 50610,N'Trạng thái không hợp lệ',1;
    IF @Status='PLANNED' AND ISNULL(@Note,N'')=N'' THROW 50611,N'Vui lòng nhập mô tả hoạt động có kế hoạch để xác nhận',1;
    UPDATE dbo.ConsumptionAnomalies SET Status=@Status,Note=@Note,HandledBy=@UserId,HandledAt=SYSDATETIME() WHERE CAnomalyId=@CAnomalyId;
    IF @@ROWCOUNT=0 THROW 50612,N'Bản ghi bất thường không tồn tại',1;
END
GO
/* =====================================================================
   UC07 - THỰC HIỆN VÀ LƯU VẾT PHÉP BIẾN ĐỔI DỮ LIỆU
   Phân rã:
     07.1 Chọn chuỗi dữ liệu lỗi (từ UC05)                          -> usp_DQ_List (UC05)
     07.2 Chọn phương pháp biến đổi                                  -> TransformMethods
     07.3 Xem trước kết quả (Preview) - KHÔNG ghi dữ liệu (BR06) «include» -> usp_Transform_Preview
     07.4 Xác nhận áp dụng (TRANSACTION)                             -> usp_Transform_Apply
     07.5 Ghi Audit Log vĩnh viễn: dữ liệu cũ/mới, người, thời gian, công thức «include» -> AuditLog (+trigger bất biến)
     07.6 Hủy thao tác: không gọi usp_Transform_Apply => dữ liệu giữ nguyên
     07.7 Xem nhật ký Audit                                          -> usp_Audit_List
     07.8 Xác nhận dữ liệu bất thường là ĐÚNG (không biến đổi)       -> usp_Anomaly_ConfirmValid
   Lỗi ghi Audit Log => XACT_ABORT tự ROLLBACK toàn bộ (luồng 4.1).
   ===================================================================== */
USE EnergyPortalDB;
GO
IF OBJECT_ID(N'dbo.TransformMethods', N'U') IS NULL
CREATE TABLE dbo.TransformMethods(
    MethodId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_TransformMethods PRIMARY KEY,
    MethodCode VARCHAR(20)   NOT NULL CONSTRAINT UQ_TM_Code UNIQUE,
    MethodName NVARCHAR(100) NOT NULL,
    FormulaDescription NVARCHAR(300) NOT NULL,
    DefaultWindow INT        NOT NULL,
    ParamLabel NVARCHAR(60)  NULL,
    IsActive   BIT           NOT NULL CONSTRAINT DF_TM_Active DEFAULT 1
);
GO
MERGE dbo.TransformMethods t USING (VALUES
 ('LINEAR_INTERP',N'Nội suy tuyến tính',N'V = Vp + (Vn - Vp) x (t - tp) / (tn - tp); p/n = điểm hợp lệ gần nhất trước/sau',2,NULL),
 ('MOVING_AVG',   N'Trung bình động',   N'V = AVG(k điểm hợp lệ trước và k điểm hợp lệ sau)',2,N'k (số điểm mỗi phía)'),
 ('NOISE_FILTER', N'Lọc nhiễu (trung vị)',N'V = MEDIAN(k điểm hợp lệ trước và k điểm hợp lệ sau)',2,N'k (số điểm mỗi phía)'),
 ('MEAN_DEFAULT', N'Gán giá trị trung bình cùng giờ',N'V = AVG(giá trị hợp lệ cùng giờ trong ±n ngày); nếu không có dùng AVG toàn chuỗi',7,N'n (số ngày)')
) s(c,n,f,w,p) ON t.MethodCode=s.c
WHEN NOT MATCHED THEN INSERT(MethodCode,MethodName,FormulaDescription,DefaultWindow,ParamLabel) VALUES(s.c,s.n,s.f,s.w,s.p);
GO
IF OBJECT_ID(N'dbo.TransformBatches', N'U') IS NULL
CREATE TABLE dbo.TransformBatches(
    TransformId BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_TransformBatches PRIMARY KEY,
    MethodId    INT           NOT NULL CONSTRAINT FK_TB_Method REFERENCES dbo.TransformMethods(MethodId),
    WindowParam INT           NOT NULL,
    Reason      NVARCHAR(500) NOT NULL,
    AppliedBy   INT           NOT NULL CONSTRAINT FK_TB_User REFERENCES dbo.Users(UserId),
    AppliedAt   DATETIME2(0)  NOT NULL CONSTRAINT DF_TB_At DEFAULT SYSDATETIME(),
    RecordCount INT           NOT NULL,
    Formula     NVARCHAR(300) NOT NULL
);
GO
IF OBJECT_ID(N'dbo.AuditLog', N'U') IS NULL
CREATE TABLE dbo.AuditLog(
    AuditId     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AuditLog PRIMARY KEY,
    TransformId BIGINT        NULL CONSTRAINT FK_Audit_TB REFERENCES dbo.TransformBatches(TransformId),
    ActionType  VARCHAR(14)   NOT NULL,
    RawId       BIGINT        NOT NULL CONSTRAINT FK_Audit_Raw REFERENCES dbo.RawTelemetry(RawId),
    MeterId     INT           NOT NULL CONSTRAINT FK_Audit_Meter REFERENCES dbo.Meters(MeterId),
    ReadingTime DATETIME2(0)  NOT NULL,
    OldValue    DECIMAL(18,3) NULL,
    NewValue    DECIMAL(18,3) NULL,
    MethodCode  VARCHAR(20)   NULL,
    Formula     NVARCHAR(300) NULL,
    Reason      NVARCHAR(500) NOT NULL,
    PerformedBy INT           NOT NULL CONSTRAINT FK_Audit_User REFERENCES dbo.Users(UserId),
    PerformedAt DATETIME2(0)  NOT NULL CONSTRAINT DF_Audit_At DEFAULT SYSDATETIME(),
    CONSTRAINT CK_Audit_Action CHECK (ActionType IN ('TRANSFORM','CONFIRM_VALID'))
);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.AuditLog') AND name=N'IX_Audit_Meter')
    CREATE INDEX IX_Audit_Meter ON dbo.AuditLog(MeterId,ReadingTime);
GO
CREATE OR ALTER TRIGGER dbo.TR_AuditLog_Immutable ON dbo.AuditLog INSTEAD OF UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 50790,N'Audit Log được lưu vĩnh viễn, không cho phép sửa hoặc xóa',1;
END
GO
IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name=N'FK_DA_Transform')
    ALTER TABLE dbo.DataAnomalies ADD CONSTRAINT FK_DA_Transform FOREIGN KEY(TransformId) REFERENCES dbo.TransformBatches(TransformId);
GO

/* Lõi tính toán dùng chung cho Preview và Apply.
   Bên gọi phải tạo sẵn: #Targets(RawId) và #Calc */
CREATE OR ALTER PROCEDURE dbo.usp_Transform_Compute @MethodCode VARCHAR(20),@Window INT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT #Calc(RawId,MeterId,ReadingTime,OldValue,AnomalyType)
    SELECT r.RawId,r.MeterId,r.ReadingTime,r.ReadingValue,a.AnomalyType
    FROM #Targets t JOIN dbo.RawTelemetry r ON r.RawId=t.RawId
    OUTER APPLY (SELECT TOP 1 d.AnomalyType FROM dbo.DataAnomalies d WHERE d.RawId=r.RawId AND d.Status='OPEN' ORDER BY d.AnomalyId) a
    WHERE r.QualityStatus='ANOMALY';

    IF @MethodCode='LINEAR_INTERP'
    BEGIN
        UPDATE c SET NewValue=CASE
              WHEN p.Val IS NOT NULL AND n.Val IS NOT NULL
                   THEN p.Val+(n.Val-p.Val)*CAST(DATEDIFF(SECOND,p.T,c.ReadingTime) AS FLOAT)/NULLIF(DATEDIFF(SECOND,p.T,n.T),0)
              WHEN p.Val IS NOT NULL THEN p.Val
              WHEN n.Val IS NOT NULL THEN n.Val END
        FROM #Calc c
        OUTER APPLY (SELECT TOP 1 x.ReadingTime AS T,x.EffectiveValue AS Val FROM dbo.RawTelemetry x
                     WHERE x.MeterId=c.MeterId AND x.ReadingTime<c.ReadingTime AND x.QualityStatus IN ('VALID','CLEANED') AND x.EffectiveValue IS NOT NULL
                     ORDER BY x.ReadingTime DESC) p
        OUTER APPLY (SELECT TOP 1 x.ReadingTime AS T,x.EffectiveValue AS Val FROM dbo.RawTelemetry x
                     WHERE x.MeterId=c.MeterId AND x.ReadingTime>c.ReadingTime AND x.QualityStatus IN ('VALID','CLEANED') AND x.EffectiveValue IS NOT NULL
                     ORDER BY x.ReadingTime ASC) n;
    END
    ELSE IF @MethodCode IN ('MOVING_AVG','NOISE_FILTER')
    BEGIN
        CREATE TABLE #nb(RawId BIGINT,Val DECIMAL(18,3));
        INSERT #nb(RawId,Val)
        SELECT c.RawId,u.Val FROM #Calc c
        CROSS APPLY (
            SELECT p.Val FROM (SELECT TOP (@Window) x.EffectiveValue AS Val FROM dbo.RawTelemetry x
                               WHERE x.MeterId=c.MeterId AND x.ReadingTime<c.ReadingTime AND x.QualityStatus IN ('VALID','CLEANED') AND x.EffectiveValue IS NOT NULL
                               ORDER BY x.ReadingTime DESC) p
            UNION ALL
            SELECT n.Val FROM (SELECT TOP (@Window) x.EffectiveValue AS Val FROM dbo.RawTelemetry x
                               WHERE x.MeterId=c.MeterId AND x.ReadingTime>c.ReadingTime AND x.QualityStatus IN ('VALID','CLEANED') AND x.EffectiveValue IS NOT NULL
                               ORDER BY x.ReadingTime ASC) n) u;
        IF @MethodCode='MOVING_AVG'
            UPDATE c SET NewValue=a.V FROM #Calc c JOIN (SELECT RawId,AVG(Val) AS V FROM #nb GROUP BY RawId) a ON a.RawId=c.RawId;
        ELSE
        BEGIN
            SELECT DISTINCT RawId,PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY Val) OVER (PARTITION BY RawId) AS V INTO #med FROM #nb;
            UPDATE c SET NewValue=m.V FROM #Calc c JOIN #med m ON m.RawId=c.RawId;
        END
    END
    ELSE IF @MethodCode='MEAN_DEFAULT'
    BEGIN
        UPDATE c SET NewValue=ISNULL(s.SameHour,s.AllAvg)
        FROM #Calc c
        CROSS APPLY (SELECT
            (SELECT AVG(x.EffectiveValue) FROM dbo.RawTelemetry x
              WHERE x.MeterId=c.MeterId AND x.QualityStatus IN ('VALID','CLEANED') AND x.EffectiveValue IS NOT NULL
                AND DATEPART(HOUR,x.ReadingTime)=DATEPART(HOUR,c.ReadingTime)
                AND x.ReadingTime>=DATEADD(DAY,-@Window,c.ReadingTime) AND x.ReadingTime<=DATEADD(DAY,@Window,c.ReadingTime)) AS SameHour,
            (SELECT AVG(x.EffectiveValue) FROM dbo.RawTelemetry x
              WHERE x.MeterId=c.MeterId AND x.QualityStatus IN ('VALID','CLEANED') AND x.EffectiveValue IS NOT NULL) AS AllAvg) s;
    END
    ELSE THROW 50710,N'Phương pháp biến đổi không được hỗ trợ',1;

    UPDATE #Calc SET NewValue=ROUND(CASE WHEN NewValue<0 THEN 0 ELSE NewValue END,3) WHERE NewValue IS NOT NULL;
    UPDATE #Calc SET Note=N'Không có điểm lân cận hợp lệ để tính' WHERE NewValue IS NULL;
END
GO

/* 07.3 Xem trước */
CREATE OR ALTER PROCEDURE dbo.usp_Transform_Preview @Targets dbo.IdListType READONLY,@MethodCode VARCHAR(20),@Window INT=2
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS(SELECT 1 FROM dbo.TransformMethods WHERE MethodCode=@MethodCode AND IsActive=1) THROW 50711,N'Phương pháp biến đổi không hợp lệ',1;
    IF @Window<1 OR @Window>60 THROW 50712,N'Tham số phương pháp phải trong khoảng 1..60',1;
    CREATE TABLE #Targets(RawId BIGINT PRIMARY KEY);
    CREATE TABLE #Calc(RawId BIGINT PRIMARY KEY,MeterId INT,ReadingTime DATETIME2(0),OldValue DECIMAL(18,3),NewValue DECIMAL(18,3),AnomalyType VARCHAR(10),Note NVARCHAR(100));
    INSERT #Targets SELECT Id FROM @Targets;
    EXEC dbo.usp_Transform_Compute @MethodCode,@Window;
    SELECT c.RawId,m.MeterCode,c.ReadingTime,c.AnomalyType,c.OldValue,c.NewValue,
           CASE WHEN c.OldValue IS NULL OR c.NewValue IS NULL THEN NULL ELSE c.NewValue-c.OldValue END AS Delta,c.Note
    FROM #Calc c JOIN dbo.Meters m ON m.MeterId=c.MeterId ORDER BY c.MeterId,c.ReadingTime;
END
GO

/* 07.4 + 07.5 Áp dụng & lưu vết (TRANSACTION) */
CREATE OR ALTER PROCEDURE dbo.usp_Transform_Apply
    @Targets dbo.IdListType READONLY,@MethodCode VARCHAR(20),@Window INT=2,@Reason NVARCHAR(500),@UserId INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @own BIT=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF ISNULL(LTRIM(RTRIM(@Reason)),N'')=N'' THROW 50701,N'Vui lòng nhập lý do điều chỉnh dữ liệu',1;
        IF NOT EXISTS(SELECT 1 FROM dbo.Users WHERE UserId=@UserId AND Status='ACTIVE') THROW 50702,N'Người thực hiện không hợp lệ',1;
        IF @Window<1 OR @Window>60 THROW 50712,N'Tham số phương pháp phải trong khoảng 1..60',1;
        DECLARE @mid INT,@formula NVARCHAR(300);
        SELECT @mid=MethodId,@formula=FormulaDescription FROM dbo.TransformMethods WHERE MethodCode=@MethodCode AND IsActive=1;
        IF @mid IS NULL THROW 50711,N'Phương pháp biến đổi không hợp lệ',1;

        CREATE TABLE #Targets(RawId BIGINT PRIMARY KEY);
        CREATE TABLE #Calc(RawId BIGINT PRIMARY KEY,MeterId INT,ReadingTime DATETIME2(0),OldValue DECIMAL(18,3),NewValue DECIMAL(18,3),AnomalyType VARCHAR(10),Note NVARCHAR(100));
        INSERT #Targets SELECT Id FROM @Targets;
        DECLARE @total INT=(SELECT COUNT(*) FROM #Targets);
        EXEC dbo.usp_Transform_Compute @MethodCode,@Window;
        DECLARE @applied INT=(SELECT COUNT(*) FROM #Calc WHERE NewValue IS NOT NULL);
        IF @applied=0 THROW 50703,N'Không có bản ghi nào đủ điều kiện biến đổi (cần dữ liệu lân cận hợp lệ)',1;
        SET @formula=@formula+N' [tham số='+CAST(@Window AS NVARCHAR(10))+N']';

        IF @own=1 BEGIN TRAN;
        INSERT dbo.TransformBatches(MethodId,WindowParam,Reason,AppliedBy,RecordCount,Formula) VALUES(@mid,@Window,@Reason,@UserId,@applied,@formula);
        DECLARE @tid BIGINT=SCOPE_IDENTITY();
        INSERT dbo.AuditLog(TransformId,ActionType,RawId,MeterId,ReadingTime,OldValue,NewValue,MethodCode,Formula,Reason,PerformedBy)
        SELECT @tid,'TRANSFORM',c.RawId,c.MeterId,c.ReadingTime,c.OldValue,c.NewValue,@MethodCode,@formula,@Reason,@UserId
        FROM #Calc c WHERE c.NewValue IS NOT NULL;
        UPDATE r SET CleanedValue=c.NewValue,QualityStatus='CLEANED',CleanedAt=SYSDATETIME()
        FROM dbo.RawTelemetry r JOIN #Calc c ON c.RawId=r.RawId WHERE c.NewValue IS NOT NULL;
        UPDATE d SET Status='RESOLVED',ResolvedAt=SYSDATETIME(),ResolvedBy=@UserId,TransformId=@tid
        FROM dbo.DataAnomalies d JOIN #Calc c ON c.RawId=d.RawId WHERE c.NewValue IS NOT NULL AND d.Status='OPEN';

        DECLARE @m INT,@a DATETIME2(0),@b DATETIME2(0);
        DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT MeterId,MIN(ReadingTime),MAX(ReadingTime) FROM #Calc WHERE NewValue IS NOT NULL GROUP BY MeterId;
        OPEN cur; FETCH NEXT FROM cur INTO @m,@a,@b;
        WHILE @@FETCH_STATUS=0 BEGIN EXEC dbo.usp_Aggregate_Meter @m,@a,@b; FETCH NEXT FROM cur INTO @m,@a,@b; END
        CLOSE cur; DEALLOCATE cur;
        IF @own=1 COMMIT;
        SELECT @tid AS TransformId,@applied AS Applied,@total-@applied AS Skipped;
    END TRY
    BEGIN CATCH
        IF @own=1 AND @@TRANCOUNT>0 ROLLBACK; THROW;
    END CATCH
END
GO

/* 07.8 Xác nhận dữ liệu bất thường là đúng thực tế (nhảy vọt có thật) - vẫn lưu vết */
CREATE OR ALTER PROCEDURE dbo.usp_Anomaly_ConfirmValid @AnomalyId BIGINT,@UserId INT,@Note NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @own BIT=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF ISNULL(@Note,N'')=N'' THROW 50720,N'Vui lòng nhập lý do xác nhận dữ liệu là đúng',1;
        DECLARE @raw BIGINT,@meter INT,@type VARCHAR(10),@st VARCHAR(10);
        SELECT @raw=RawId,@meter=MeterId,@type=AnomalyType,@st=Status FROM dbo.DataAnomalies WHERE AnomalyId=@AnomalyId;
        IF @meter IS NULL THROW 50721,N'Bản ghi bất thường không tồn tại',1;
        IF @st<>'OPEN' THROW 50722,N'Bản ghi đã được xử lý',1;
        IF @type IN ('NEGATIVE','MISSING') THROW 50723,N'Chỉ số âm / khuyết dữ liệu không thể xác nhận là đúng, hãy dùng phép biến đổi',1;
        IF @own=1 BEGIN TRAN;
        IF @type='NO_SIGNAL'
            UPDATE dbo.DataAnomalies SET Status='IGNORED',ResolvedAt=SYSDATETIME(),ResolvedBy=@UserId,Note=@Note WHERE AnomalyId=@AnomalyId;
        ELSE
        BEGIN
            DECLARE @t DATETIME2(0),@v DECIMAL(18,3);
            SELECT @t=ReadingTime,@v=ReadingValue FROM dbo.RawTelemetry WHERE RawId=@raw;
            UPDATE dbo.RawTelemetry SET QualityStatus='VALID' WHERE RawId=@raw;
            UPDATE dbo.DataAnomalies SET Status='IGNORED',ResolvedAt=SYSDATETIME(),ResolvedBy=@UserId,Note=@Note WHERE AnomalyId=@AnomalyId;
            INSERT dbo.AuditLog(TransformId,ActionType,RawId,MeterId,ReadingTime,OldValue,NewValue,MethodCode,Formula,Reason,PerformedBy)
            VALUES(NULL,'CONFIRM_VALID',@raw,@meter,@t,@v,@v,NULL,N'Giữ nguyên giá trị (xác nhận đúng thực tế)',@Note,@UserId);
            EXEC dbo.usp_Aggregate_Meter @meter,@t,@t;
        END
        IF @own=1 COMMIT;
    END TRY
    BEGIN CATCH
        IF @own=1 AND @@TRANCOUNT>0 ROLLBACK; THROW;
    END CATCH
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Transform_Methods_List AS BEGIN SET NOCOUNT ON;
    SELECT MethodId,MethodCode,MethodName,FormulaDescription,DefaultWindow,ParamLabel FROM dbo.TransformMethods WHERE IsActive=1 ORDER BY MethodId; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Audit_List
    @MeterId INT=NULL,@From DATETIME2(0)=NULL,@To DATETIME2(0)=NULL,@UserId INT=NULL,@ActionType VARCHAR(14)=NULL,@Top INT=2000
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Top) a.AuditId,a.TransformId,a.ActionType,m.MeterCode,a.ReadingTime,a.OldValue,a.NewValue,a.MethodCode,a.Formula,
           a.Reason,u.FullName AS PerformedByName,a.PerformedAt
    FROM dbo.AuditLog a JOIN dbo.Meters m ON m.MeterId=a.MeterId JOIN dbo.Users u ON u.UserId=a.PerformedBy
    WHERE (@MeterId IS NULL OR a.MeterId=@MeterId) AND (@UserId IS NULL OR a.PerformedBy=@UserId) AND (@ActionType IS NULL OR a.ActionType=@ActionType)
      AND (@From IS NULL OR a.PerformedAt>=@From) AND (@To IS NULL OR a.PerformedAt<=@To)
    ORDER BY a.AuditId DESC;
END
GO
/* =====================================================================
   UC08 - LẬP VÀ QUẢN LÝ KẾ HOẠCH TIẾT KIỆM NĂNG LƯỢNG
   Phân rã:
     08.1 Tạo / sửa kế hoạch (khóa mã khi sửa)                    -> usp_Plan_Save
     08.2 Kiểm tra mục tiêu 0% < % <= 100% (BR07) «include»       -> CK_Plans_Target + usp_Plan_Save
     08.3 Khai báo danh sách giải pháp thực hiện                  -> PlanSolutions, usp_Solution_*
     08.4 Kích hoạt theo dõi: trạng thái "Đang thực hiện"          -> Status = RUNNING
     08.5 Hoàn thành / hủy kế hoạch                               -> usp_Plan_SetStatus, usp_Plan_RefreshStatus
     08.6 Xóa kế hoạch chưa phát sinh KPI                         -> usp_Plan_Delete (FK chặn)
   ===================================================================== */
USE EnergyPortalDB;
GO
IF OBJECT_ID(N'dbo.SavingPlans', N'U') IS NULL
CREATE TABLE dbo.SavingPlans(
    PlanId        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_SavingPlans PRIMARY KEY,
    PlanCode      VARCHAR(20)   NOT NULL CONSTRAINT UQ_Plans_Code UNIQUE,
    PlanName      NVARCHAR(150) NOT NULL,
    BuildingId    INT           NOT NULL CONSTRAINT FK_Plans_Building REFERENCES dbo.Buildings(BuildingId),
    FloorId       INT           NULL CONSTRAINT FK_Plans_Floor REFERENCES dbo.Floors(FloorId),
    RoomId        INT           NULL CONSTRAINT FK_Plans_Room  REFERENCES dbo.Rooms(RoomId),
    EnergyTypeId  INT           NOT NULL CONSTRAINT FK_Plans_Energy REFERENCES dbo.EnergyTypes(EnergyTypeId),
    TargetPercent DECIMAL(5,2)  NOT NULL,
    StartDate     DATE          NOT NULL,
    EndDate       DATE          NOT NULL,
    BaselineDays  INT           NOT NULL CONSTRAINT DF_Plans_BDays DEFAULT 28,
    BaselineFrom  DATE          NOT NULL,
    BaselineTo    DATE          NOT NULL,
    Status        VARCHAR(10)   NOT NULL CONSTRAINT DF_Plans_Status DEFAULT 'RUNNING',
    Description   NVARCHAR(500) NULL,
    CreatedBy     INT           NULL CONSTRAINT FK_Plans_User REFERENCES dbo.Users(UserId),
    CreatedAt     DATETIME2(0)  NOT NULL CONSTRAINT DF_Plans_Created DEFAULT SYSDATETIME(),
    UpdatedAt     DATETIME2(0)  NULL,
    CONSTRAINT CK_Plans_Target CHECK (TargetPercent>0 AND TargetPercent<=100),          -- BR07
    CONSTRAINT CK_Plans_Dates  CHECK (EndDate>=StartDate),
    CONSTRAINT CK_Plans_Status CHECK (Status IN ('RUNNING','COMPLETED','CANCELLED')),
    CONSTRAINT CK_Plans_Scope  CHECK (RoomId IS NULL OR FloorId IS NOT NULL),
    CONSTRAINT CK_Plans_BDays  CHECK (BaselineDays BETWEEN 7 AND 365)
);
GO
IF OBJECT_ID(N'dbo.PlanSolutions', N'U') IS NULL
CREATE TABLE dbo.PlanSolutions(
    SolutionId    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PlanSolutions PRIMARY KEY,
    PlanId        INT           NOT NULL CONSTRAINT FK_Sol_Plan REFERENCES dbo.SavingPlans(PlanId),
    SolutionName  NVARCHAR(150) NOT NULL,
    Description   NVARCHAR(300) NULL,
    ExpectedSavingPercent DECIMAL(5,2) NULL,
    Status        VARCHAR(12)   NOT NULL CONSTRAINT DF_Sol_Status DEFAULT 'PLANNED',
    AssignedTo    NVARCHAR(100) NULL,
    DueDate       DATE          NULL,
    CONSTRAINT CK_Sol_Status CHECK (Status IN ('PLANNED','IN_PROGRESS','DONE')),
    CONSTRAINT CK_Sol_Pct CHECK (ExpectedSavingPercent IS NULL OR (ExpectedSavingPercent>=0 AND ExpectedSavingPercent<=100))
);
GO
CREATE OR ALTER PROCEDURE dbo.usp_Plan_Save
    @PlanId INT=NULL,@PlanCode VARCHAR(20),@PlanName NVARCHAR(150),@BuildingId INT,@FloorId INT=NULL,@RoomId INT=NULL,
    @EnergyTypeId INT,@TargetPercent DECIMAL(5,2),@StartDate DATE,@EndDate DATE,@BaselineDays INT=28,
    @Description NVARCHAR(500)=NULL,@UserId INT=NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @PlanCode=UPPER(LTRIM(RTRIM(@PlanCode)));
    IF ISNULL(@PlanCode,'')='' OR ISNULL(@PlanName,N'')=N'' THROW 50801,N'Mã và tên kế hoạch là bắt buộc',1;
    IF @TargetPercent IS NULL OR @TargetPercent<=0 OR @TargetPercent>100
        THROW 50802,N'Mục tiêu tiết kiệm phải nằm trong khoảng 0% < mục tiêu <= 100%',1;
    IF @EndDate<@StartDate THROW 50803,N'Ngày kết thúc phải sau ngày bắt đầu',1;
    IF @BaselineDays<7 OR @BaselineDays>365 THROW 50804,N'Số ngày đường cơ sở phải trong khoảng 7..365',1;
    IF @RoomId IS NOT NULL AND @FloorId IS NULL THROW 50805,N'Chọn phòng thì phải chọn tầng',1;
    IF @FloorId IS NOT NULL AND NOT EXISTS(SELECT 1 FROM dbo.Floors WHERE FloorId=@FloorId AND BuildingId=@BuildingId) THROW 50806,N'Tầng không thuộc tòa nhà đã chọn',1;
    IF @RoomId IS NOT NULL AND NOT EXISTS(SELECT 1 FROM dbo.Rooms WHERE RoomId=@RoomId AND FloorId=@FloorId) THROW 50807,N'Phòng không thuộc tầng đã chọn',1;
    IF EXISTS(SELECT 1 FROM dbo.SavingPlans WHERE PlanCode=@PlanCode AND PlanId<>ISNULL(@PlanId,0)) THROW 50808,N'Mã kế hoạch đã tồn tại',1;
    IF NOT EXISTS(SELECT 1 FROM dbo.fn_MetersInScope(@BuildingId,@FloorId,@RoomId,@EnergyTypeId))
        THROW 50809,N'Khu vực đã chọn chưa có công tơ nào thuộc loại năng lượng này',1;
    DECLARE @bf DATE=DATEADD(DAY,-@BaselineDays,@StartDate),@bt DATE=DATEADD(DAY,-1,@StartDate);
    IF @PlanId IS NULL
    BEGIN
        INSERT dbo.SavingPlans(PlanCode,PlanName,BuildingId,FloorId,RoomId,EnergyTypeId,TargetPercent,StartDate,EndDate,BaselineDays,BaselineFrom,BaselineTo,Status,Description,CreatedBy)
        VALUES(@PlanCode,@PlanName,@BuildingId,@FloorId,@RoomId,@EnergyTypeId,@TargetPercent,@StartDate,@EndDate,@BaselineDays,@bf,@bt,'RUNNING',@Description,@UserId);
        SELECT SCOPE_IDENTITY() AS PlanId;
    END
    ELSE
    BEGIN   -- khóa mã kế hoạch khi sửa; không cho đổi phạm vi/năng lượng nếu đã có KPI
        IF EXISTS(SELECT 1 FROM dbo.PlanKPI WHERE PlanId=@PlanId) AND EXISTS(SELECT 1 FROM dbo.SavingPlans WHERE PlanId=@PlanId
              AND (BuildingId<>@BuildingId OR ISNULL(FloorId,0)<>ISNULL(@FloorId,0) OR ISNULL(RoomId,0)<>ISNULL(@RoomId,0) OR EnergyTypeId<>@EnergyTypeId
                   OR StartDate<>@StartDate OR BaselineDays<>@BaselineDays))
            THROW 50810,N'Kế hoạch đã có KPI, không được đổi phạm vi, loại năng lượng, ngày bắt đầu hoặc số ngày đường cơ sở',1;
        UPDATE dbo.SavingPlans SET PlanName=@PlanName,BuildingId=@BuildingId,FloorId=@FloorId,RoomId=@RoomId,EnergyTypeId=@EnergyTypeId,
               TargetPercent=@TargetPercent,StartDate=@StartDate,EndDate=@EndDate,BaselineDays=@BaselineDays,BaselineFrom=@bf,BaselineTo=@bt,
               Description=@Description,UpdatedAt=SYSDATETIME() WHERE PlanId=@PlanId;
        SELECT @PlanId AS PlanId;
    END
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Plan_RefreshStatus AS
BEGIN SET NOCOUNT ON;
    UPDATE dbo.SavingPlans SET Status='COMPLETED',UpdatedAt=SYSDATETIME() WHERE Status='RUNNING' AND EndDate<CAST(SYSDATETIME() AS DATE); END
GO
CREATE OR ALTER VIEW dbo.vw_PlanDetail AS
SELECT p.PlanId,p.PlanCode,p.PlanName,p.BuildingId,b.BuildingName,p.FloorId,f.FloorName,p.RoomId,r.RoomName,
       COALESCE(r.RoomName,f.FloorName,b.BuildingName) AS AreaName,
       p.EnergyTypeId,e.Name AS EnergyName,e.Unit,p.TargetPercent,p.StartDate,p.EndDate,p.BaselineDays,p.BaselineFrom,p.BaselineTo,
       p.Status,p.Description,
       (SELECT COUNT(*) FROM dbo.PlanSolutions s WHERE s.PlanId=p.PlanId) AS SolutionCount,
       (SELECT COUNT(*) FROM dbo.PlanSolutions s WHERE s.PlanId=p.PlanId AND s.Status='DONE') AS SolutionDone
FROM dbo.SavingPlans p JOIN dbo.Buildings b ON b.BuildingId=p.BuildingId JOIN dbo.EnergyTypes e ON e.EnergyTypeId=p.EnergyTypeId
LEFT JOIN dbo.Floors f ON f.FloorId=p.FloorId LEFT JOIN dbo.Rooms r ON r.RoomId=p.RoomId;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Plan_List @Status VARCHAR(10)=NULL,@BuildingId INT=NULL
AS BEGIN SET NOCOUNT ON;
    EXEC dbo.usp_Plan_RefreshStatus;
    SELECT * FROM dbo.vw_PlanDetail WHERE (@Status IS NULL OR Status=@Status) AND (@BuildingId IS NULL OR BuildingId=@BuildingId) ORDER BY StartDate DESC,PlanCode; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Plan_SetStatus @PlanId INT,@Status VARCHAR(10)
AS BEGIN SET NOCOUNT ON;
    IF @Status NOT IN ('RUNNING','COMPLETED','CANCELLED') THROW 50811,N'Trạng thái kế hoạch không hợp lệ',1;
    UPDATE dbo.SavingPlans SET Status=@Status,UpdatedAt=SYSDATETIME() WHERE PlanId=@PlanId; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Plan_Delete @PlanId INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DELETE dbo.PlanSolutions WHERE PlanId=@PlanId;
        DELETE dbo.SavingPlans WHERE PlanId=@PlanId;
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT>0 ROLLBACK;
        IF ERROR_NUMBER()=547 THROW 50812,N'Kế hoạch đã phát sinh KPI, chỉ có thể chuyển sang trạng thái Hủy',1;
        THROW;
    END CATCH
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Solution_Save
    @SolutionId INT=NULL,@PlanId INT,@SolutionName NVARCHAR(150),@Description NVARCHAR(300)=NULL,
    @ExpectedSavingPercent DECIMAL(5,2)=NULL,@Status VARCHAR(12)='PLANNED',@AssignedTo NVARCHAR(100)=NULL,@DueDate DATE=NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF ISNULL(@SolutionName,N'')=N'' THROW 50820,N'Tên giải pháp là bắt buộc',1;
    IF @ExpectedSavingPercent IS NOT NULL AND (@ExpectedSavingPercent<0 OR @ExpectedSavingPercent>100) THROW 50821,N'% tiết kiệm dự kiến phải trong khoảng 0..100',1;
    IF NOT EXISTS(SELECT 1 FROM dbo.SavingPlans WHERE PlanId=@PlanId) THROW 50822,N'Kế hoạch không tồn tại',1;
    IF @SolutionId IS NULL
        INSERT dbo.PlanSolutions(PlanId,SolutionName,Description,ExpectedSavingPercent,Status,AssignedTo,DueDate)
        VALUES(@PlanId,@SolutionName,@Description,@ExpectedSavingPercent,@Status,@AssignedTo,@DueDate);
    ELSE
        UPDATE dbo.PlanSolutions SET SolutionName=@SolutionName,Description=@Description,ExpectedSavingPercent=@ExpectedSavingPercent,
               Status=@Status,AssignedTo=@AssignedTo,DueDate=@DueDate WHERE SolutionId=@SolutionId;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Solution_Delete @SolutionId INT AS BEGIN SET NOCOUNT ON; DELETE dbo.PlanSolutions WHERE SolutionId=@SolutionId; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Solution_List @PlanId INT AS BEGIN SET NOCOUNT ON;
    SELECT SolutionId,PlanId,SolutionName,Description,ExpectedSavingPercent,Status,AssignedTo,DueDate FROM dbo.PlanSolutions WHERE PlanId=@PlanId ORDER BY SolutionId; END
GO
/* =====================================================================
   UC09 - THEO DÕI VÀ ĐÁNH GIÁ HIỆU QUẢ KẾ HOẠCH TIẾT KIỆM
   Phân rã:
     09.1 Chọn kế hoạch cần đánh giá                                  -> usp_Plan_List (UC08)
     09.2 Tính đường cơ sở (Baseline) của kế hoạch - dữ liệu sạch (BR08) «include» -> fn_ScopeDaily
     09.3 Tính KPI: % tiết kiệm, kWh giảm, chi phí giảm, % đạt mục tiêu «include» -> usp_KPI_Calculate
     09.4 «extend» Cảnh báo tiến độ chậm + gợi ý giải pháp bổ sung    -> Status = BEHIND, Suggestion
     09.5 Biểu đồ so sánh thực tế - Baseline - mục tiêu               -> usp_KPI_Series
     09.6 Lịch sử KPI / tổng hợp cho Ban quản lý                      -> usp_KPI_History, vw_PlanLatestKPI
   Phương pháp: Baseline = TB ngày thường / TB cuối tuần của khoảng đường cơ sở (chỉ những ngày TẤT CẢ công tơ đạt chất lượng).
                Kỳ vọng mỗi ngày kế hoạch = Baseline theo loại ngày; Tiết kiệm = Kỳ vọng - Thực tế.
   ===================================================================== */
USE EnergyPortalDB;
GO
IF OBJECT_ID(N'dbo.PlanKPI', N'U') IS NULL
CREATE TABLE dbo.PlanKPI(
    KpiId        BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PlanKPI PRIMARY KEY,
    PlanId       INT           NOT NULL CONSTRAINT FK_KPI_Plan REFERENCES dbo.SavingPlans(PlanId),
    CalcAt       DATETIME2(0)  NOT NULL CONSTRAINT DF_KPI_At DEFAULT SYSDATETIME(),
    PeriodFrom   DATE NOT NULL, PeriodTo DATE NOT NULL,
    DaysCounted  INT NOT NULL, DaysIncomplete INT NOT NULL,
    BaselineValue DECIMAL(18,3) NOT NULL,       -- tiêu thụ kỳ vọng nếu không có kế hoạch
    ActualValue   DECIMAL(18,3) NOT NULL,
    SavedValue    DECIMAL(18,3) NOT NULL,
    SavedPercent  DECIMAL(9,2)  NOT NULL,
    TargetPercent DECIMAL(5,2)  NOT NULL,
    AchievementPercent DECIMAL(9,2) NOT NULL,   -- SavedPercent / TargetPercent
    SavedCost     DECIMAL(18,2) NOT NULL,
    Status        VARCHAR(10)   NOT NULL,
    Suggestion    NVARCHAR(600) NULL,
    CalculatedBy  INT NULL CONSTRAINT FK_KPI_User REFERENCES dbo.Users(UserId),
    CONSTRAINT CK_KPI_Status CHECK (Status IN ('ACHIEVED','ON_TRACK','BEHIND'))
);
GO
CREATE INDEX IX_KPI_Plan ON dbo.PlanKPI(PlanId,CalcAt DESC);
GO
/* Tổng tiêu thụ theo NGÀY của một phạm vi; chỉ ngày có CompleteMeters = MeterCount mới được dùng (BR08) */
CREATE OR ALTER FUNCTION dbo.fn_ScopeDaily(@BuildingId INT,@FloorId INT,@RoomId INT,@EnergyTypeId INT,@From DATE,@To DATE)
RETURNS TABLE AS RETURN
SELECT CAST(a.PeriodStart AS DATE) AS DayDate,SUM(a.TotalValue) AS TotalValue,
       SUM(CASE WHEN a.IsComplete=1 THEN 1 ELSE 0 END) AS CompleteMeters,mc.MeterCount
FROM dbo.EnergyAggregates a
JOIN dbo.fn_MetersInScope(@BuildingId,@FloorId,@RoomId,@EnergyTypeId) s ON s.MeterId=a.MeterId
CROSS JOIN (SELECT COUNT(*) AS MeterCount FROM dbo.fn_MetersInScope(@BuildingId,@FloorId,@RoomId,@EnergyTypeId)) mc
WHERE a.PeriodType='DAY' AND a.PeriodStart>=CAST(@From AS DATETIME2(0)) AND a.PeriodStart<DATEADD(DAY,1,CAST(@To AS DATETIME2(0)))
GROUP BY CAST(a.PeriodStart AS DATE),mc.MeterCount;
GO
CREATE OR ALTER PROCEDURE dbo.usp_KPI_Calculate @PlanId INT,@UserId INT,@AsOf DATE=NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        DECLARE @b INT,@f INT,@r INT,@e INT,@t DECIMAL(5,2),@s DATE,@en DATE,@bf DATE,@bt DATE;
        SELECT @b=BuildingId,@f=FloorId,@r=RoomId,@e=EnergyTypeId,@t=TargetPercent,@s=StartDate,@en=EndDate,@bf=BaselineFrom,@bt=BaselineTo
        FROM dbo.SavingPlans WHERE PlanId=@PlanId;
        IF @b IS NULL THROW 50901,N'Kế hoạch không tồn tại',1;
        SET @AsOf=ISNULL(@AsOf,CAST(SYSDATETIME() AS DATE));
        IF @AsOf<@s THROW 50902,N'Kế hoạch chưa bắt đầu, chưa có dữ liệu để đánh giá',1;
        DECLARE @to DATE=CASE WHEN @AsOf<@en THEN @AsOf ELSE @en END;

        DECLARE @avgWd DECIMAL(18,3),@avgWe DECIMAL(18,3),@avgAll DECIMAL(18,3);
        SELECT @avgWd=AVG(CASE WHEN dbo.fn_DayType(DayDate)='WEEKDAY' THEN TotalValue END),
               @avgWe=AVG(CASE WHEN dbo.fn_DayType(DayDate)='WEEKEND' THEN TotalValue END),
               @avgAll=AVG(TotalValue)
        FROM dbo.fn_ScopeDaily(@b,@f,@r,@e,@bf,@bt) WHERE MeterCount>0 AND CompleteMeters=MeterCount;
        IF @avgAll IS NULL THROW 50903,N'Chưa đủ dữ liệu đường cơ sở hợp lệ (BR08) trong khoảng đường cơ sở của kế hoạch',1;
        SET @avgWd=ISNULL(@avgWd,@avgAll); SET @avgWe=ISNULL(@avgWe,@avgAll);

        SELECT DayDate,TotalValue,CAST(CASE WHEN dbo.fn_DayType(DayDate)='WEEKEND' THEN @avgWe ELSE @avgWd END AS DECIMAL(18,3)) AS Expected
        INTO #kpi FROM dbo.fn_ScopeDaily(@b,@f,@r,@e,@s,@to) WHERE MeterCount>0 AND CompleteMeters=MeterCount;
        IF NOT EXISTS(SELECT 1 FROM #kpi) THROW 50904,N'Chưa có ngày nào trong kỳ kế hoạch đủ dữ liệu hợp lệ để đánh giá',1;

        DECLARE @days INT=(SELECT COUNT(*) FROM #kpi),@total INT=DATEDIFF(DAY,@s,@to)+1;
        DECLARE @act DECIMAL(18,3)=(SELECT SUM(TotalValue) FROM #kpi),@base DECIMAL(18,3)=(SELECT SUM(Expected) FROM #kpi);
        DECLARE @saved DECIMAL(18,3)=@base-@act;
        DECLARE @spct DECIMAL(9,2)=CASE WHEN @base>0 THEN CAST(@saved*100.0/@base AS DECIMAL(9,2)) ELSE 0 END;
        DECLARE @ach DECIMAL(9,2)=CAST(@spct*100.0/@t AS DECIMAL(9,2));
        DECLARE @th DECIMAL(18,4)=dbo.fn_SettingNum('KPI_BEHIND_THRESHOLD');
        DECLARE @price DECIMAL(18,2)=(SELECT PricePerUnit FROM dbo.EnergyTypes WHERE EnergyTypeId=@e);
        DECLARE @st VARCHAR(10)=CASE WHEN @spct>=@t THEN 'ACHIEVED' WHEN @ach<@th THEN 'BEHIND' ELSE 'ON_TRACK' END;
        DECLARE @sug NVARCHAR(600)=NULL;
        IF @st='BEHIND'
            SET @sug=N'Tiến độ chậm: mới đạt '+CAST(@ach AS NVARCHAR(20))+N'% mục tiêu ('+CAST(@spct AS NVARCHAR(20))+N'% / '+CAST(@t AS NVARCHAR(20))+N'%). '+
                     ISNULL((SELECT N'Giải pháp chưa hoàn thành cần đẩy nhanh: '+STRING_AGG(SolutionName,N'; ') FROM dbo.PlanSolutions WHERE PlanId=@PlanId AND Status<>'DONE'),
                            N'Chưa có giải pháp nào, hãy bổ sung (điều chỉnh nhiệt độ điều hòa, tắt thiết bị ngoài giờ, bảo trì thiết bị...).');
        ELSE IF @st='ACHIEVED' SET @sug=N'Đã đạt mục tiêu tiết kiệm. Duy trì các giải pháp đang áp dụng.';

        INSERT dbo.PlanKPI(PlanId,PeriodFrom,PeriodTo,DaysCounted,DaysIncomplete,BaselineValue,ActualValue,SavedValue,SavedPercent,
                           TargetPercent,AchievementPercent,SavedCost,Status,Suggestion,CalculatedBy)
        VALUES(@PlanId,@s,@to,@days,@total-@days,@base,@act,@saved,@spct,@t,@ach,CAST(@saved*@price AS DECIMAL(18,2)),@st,@sug,@UserId);
        SELECT * FROM dbo.PlanKPI WHERE KpiId=SCOPE_IDENTITY();
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_KPI_Series @PlanId INT,@AsOf DATE=NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @b INT,@f INT,@r INT,@e INT,@t DECIMAL(5,2),@s DATE,@en DATE,@bf DATE,@bt DATE;
    SELECT @b=BuildingId,@f=FloorId,@r=RoomId,@e=EnergyTypeId,@t=TargetPercent,@s=StartDate,@en=EndDate,@bf=BaselineFrom,@bt=BaselineTo
    FROM dbo.SavingPlans WHERE PlanId=@PlanId;
    IF @b IS NULL THROW 50901,N'Kế hoạch không tồn tại',1;
    SET @AsOf=ISNULL(@AsOf,CAST(SYSDATETIME() AS DATE));
    DECLARE @to DATE=CASE WHEN @AsOf<@en THEN @AsOf ELSE @en END;
    DECLARE @avgWd DECIMAL(18,3),@avgWe DECIMAL(18,3),@avgAll DECIMAL(18,3);
    SELECT @avgWd=AVG(CASE WHEN dbo.fn_DayType(DayDate)='WEEKDAY' THEN TotalValue END),
           @avgWe=AVG(CASE WHEN dbo.fn_DayType(DayDate)='WEEKEND' THEN TotalValue END),@avgAll=AVG(TotalValue)
    FROM dbo.fn_ScopeDaily(@b,@f,@r,@e,@bf,@bt) WHERE MeterCount>0 AND CompleteMeters=MeterCount;
    SET @avgWd=ISNULL(@avgWd,@avgAll); SET @avgWe=ISNULL(@avgWe,@avgAll);
    SELECT d.DayDate,
           CASE WHEN d.MeterCount>0 AND d.CompleteMeters=d.MeterCount THEN d.TotalValue END AS ActualValue,
           CASE WHEN d.DayDate>=@s THEN CASE WHEN dbo.fn_DayType(d.DayDate)='WEEKEND' THEN @avgWe ELSE @avgWd END END AS ExpectedValue,
           CASE WHEN d.DayDate>=@s THEN CAST((CASE WHEN dbo.fn_DayType(d.DayDate)='WEEKEND' THEN @avgWe ELSE @avgWd END)*(1-@t/100.0) AS DECIMAL(18,3)) END AS TargetValue,
           CAST(CASE WHEN d.DayDate>=@s THEN 1 ELSE 0 END AS BIT) AS InPlan
    FROM dbo.fn_ScopeDaily(@b,@f,@r,@e,@bf,@to) d ORDER BY d.DayDate;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_KPI_History @PlanId INT
AS BEGIN SET NOCOUNT ON;
    SELECT k.KpiId,k.CalcAt,k.PeriodFrom,k.PeriodTo,k.DaysCounted,k.DaysIncomplete,k.BaselineValue,k.ActualValue,k.SavedValue,k.SavedPercent,
           k.TargetPercent,k.AchievementPercent,k.SavedCost,k.Status,k.Suggestion,u.FullName AS CalculatedByName
    FROM dbo.PlanKPI k LEFT JOIN dbo.Users u ON u.UserId=k.CalculatedBy WHERE k.PlanId=@PlanId ORDER BY k.KpiId DESC; END
GO
/* KPI mới nhất mỗi kế hoạch (Ban quản lý tòa nhà xem) */
CREATE OR ALTER VIEW dbo.vw_PlanLatestKPI AS
SELECT p.PlanId,p.PlanCode,p.PlanName,p.AreaName,p.EnergyName,p.Unit,p.TargetPercent,p.StartDate,p.EndDate,p.Status AS PlanStatus,
       k.CalcAt,k.SavedValue,k.SavedPercent,k.AchievementPercent,k.SavedCost,k.Status AS KpiStatus,k.Suggestion
FROM dbo.vw_PlanDetail p
OUTER APPLY (SELECT TOP 1 * FROM dbo.PlanKPI x WHERE x.PlanId=p.PlanId ORDER BY x.KpiId DESC) k;
GO
CREATE OR ALTER PROCEDURE dbo.usp_KPI_Summary AS BEGIN SET NOCOUNT ON;
    EXEC dbo.usp_Plan_RefreshStatus;
    SELECT * FROM dbo.vw_PlanLatestKPI ORDER BY StartDate DESC; END
GO
/* =====================================================================
   UC10 - XEM DASHBOARD TRỰC QUAN VÀ XUẤT BÁO CÁO
   Phân rã:
     10.1 Tổng quan KPI (tiêu thụ, chi phí, cảnh báo, bất thường)   -> usp_Dash_Summary
     10.2 Biểu đồ phụ tải theo giờ/ngày                            -> usp_Dash_LoadProfile
     10.3 Bản đồ nhiệt (Heatmap) tầng x giờ                        -> usp_Dash_Heatmap
     10.4 Trạng thái công tơ thời gian thực                        -> usp_Dash_MeterStatus
     10.5 Bộ lọc tòa nhà/tầng/loại năng lượng/thời gian            -> tham số các proc
     10.6 Xuất báo cáo Excel / PDF (chỉ dữ liệu sạch, BR08)         -> usp_Report_Consumption + ReportExports
     10.7 Không có dữ liệu: form hiển thị thông báo yêu cầu chọn lại
   ===================================================================== */
USE EnergyPortalDB;
GO
IF OBJECT_ID(N'dbo.ReportExports', N'U') IS NULL
CREATE TABLE dbo.ReportExports(
    ExportId    BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ReportExports PRIMARY KEY,
    ReportType  VARCHAR(20)   NOT NULL,
    Format      VARCHAR(5)    NOT NULL,
    Filters     NVARCHAR(300) NULL,
    RecordCount INT           NOT NULL,
    FilePath    NVARCHAR(300) NULL,
    ExportedBy  INT           NOT NULL CONSTRAINT FK_Export_User REFERENCES dbo.Users(UserId),
    ExportedAt  DATETIME2(0)  NOT NULL CONSTRAINT DF_Export_At DEFAULT SYSDATETIME(),
    CONSTRAINT CK_Export_Format CHECK (Format IN ('PDF','XLSX','CSV'))
);
GO
CREATE OR ALTER PROCEDURE dbo.usp_Dash_Summary @BuildingId INT=NULL,@EnergyTypeId INT,@From DATETIME2(0),@To DATETIME2(0)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @total DECIMAL(18,3)=ISNULL((SELECT SUM(a.TotalValue) FROM dbo.EnergyAggregates a
        JOIN dbo.Meters m ON m.MeterId=a.MeterId JOIN dbo.Floors f ON f.FloorId=m.FloorId
        WHERE a.PeriodType='HOUR' AND m.EnergyTypeId=@EnergyTypeId AND (@BuildingId IS NULL OR f.BuildingId=@BuildingId)
          AND a.PeriodStart>=@From AND a.PeriodStart<@To),0);
    DECLARE @price DECIMAL(18,2)=(SELECT PricePerUnit FROM dbo.EnergyTypes WHERE EnergyTypeId=@EnergyTypeId);
    SELECT e.Name AS EnergyName,e.Unit,@total AS TotalValue,CAST(@total*@price AS DECIMAL(18,0)) AS TotalCost,
      (SELECT COUNT(*) FROM dbo.Meters m JOIN dbo.Floors f ON f.FloorId=m.FloorId
        WHERE m.EnergyTypeId=@EnergyTypeId AND m.Status='ACTIVE' AND (@BuildingId IS NULL OR f.BuildingId=@BuildingId)) AS ActiveMeters,
      (SELECT COUNT(DISTINCT d.MeterId) FROM dbo.DataAnomalies d JOIN dbo.Meters m ON m.MeterId=d.MeterId JOIN dbo.Floors f ON f.FloorId=m.FloorId
        WHERE d.AnomalyType='NO_SIGNAL' AND d.Status='OPEN' AND m.EnergyTypeId=@EnergyTypeId AND (@BuildingId IS NULL OR f.BuildingId=@BuildingId)) AS NoSignalMeters,
      (SELECT COUNT(*) FROM dbo.QuotaAlerts a JOIN dbo.Quotas q ON q.QuotaId=a.QuotaId
        WHERE a.Severity='RED' AND a.Status<>'RESOLVED' AND q.EnergyTypeId=@EnergyTypeId AND (@BuildingId IS NULL OR q.BuildingId=@BuildingId)) AS RedAlerts,
      (SELECT COUNT(*) FROM dbo.QuotaAlerts a JOIN dbo.Quotas q ON q.QuotaId=a.QuotaId
        WHERE a.Severity='YELLOW' AND a.Status<>'RESOLVED' AND q.EnergyTypeId=@EnergyTypeId AND (@BuildingId IS NULL OR q.BuildingId=@BuildingId)) AS YellowAlerts,
      (SELECT COUNT(*) FROM dbo.DataAnomalies d JOIN dbo.Meters m ON m.MeterId=d.MeterId JOIN dbo.Floors f ON f.FloorId=m.FloorId
        WHERE d.Status='OPEN' AND m.EnergyTypeId=@EnergyTypeId AND (@BuildingId IS NULL OR f.BuildingId=@BuildingId)) AS OpenDataAnomalies,
      (SELECT COUNT(*) FROM dbo.ConsumptionAnomalies c JOIN dbo.Meters m ON m.MeterId=c.MeterId JOIN dbo.Floors f ON f.FloorId=m.FloorId
        WHERE c.Status='NEW' AND m.EnergyTypeId=@EnergyTypeId AND (@BuildingId IS NULL OR f.BuildingId=@BuildingId)) AS NewConsumptionAnomalies,
      (SELECT COUNT(*) FROM dbo.SavingPlans p WHERE p.Status='RUNNING' AND p.EnergyTypeId=@EnergyTypeId AND (@BuildingId IS NULL OR p.BuildingId=@BuildingId)) AS RunningPlans
    FROM dbo.EnergyTypes e WHERE e.EnergyTypeId=@EnergyTypeId;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Dash_LoadProfile @BuildingId INT=NULL,@EnergyTypeId INT,@From DATETIME2(0),@To DATETIME2(0),@Grain VARCHAR(5)='HOUR'
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.PeriodStart,SUM(a.TotalValue) AS TotalValue,MIN(CAST(a.IsComplete AS INT)) AS AllComplete
    FROM dbo.EnergyAggregates a JOIN dbo.Meters m ON m.MeterId=a.MeterId JOIN dbo.Floors f ON f.FloorId=m.FloorId
    WHERE a.PeriodType=@Grain AND m.EnergyTypeId=@EnergyTypeId AND (@BuildingId IS NULL OR f.BuildingId=@BuildingId)
      AND a.PeriodStart>=@From AND a.PeriodStart<@To
    GROUP BY a.PeriodStart ORDER BY a.PeriodStart;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Dash_ByFloor @BuildingId INT=NULL,@EnergyTypeId INT,@From DATETIME2(0),@To DATETIME2(0)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT f.FloorNo,b.BuildingName+N' - '+f.FloorName AS FloorName,SUM(a.TotalValue) AS TotalValue
    FROM dbo.EnergyAggregates a JOIN dbo.Meters m ON m.MeterId=a.MeterId JOIN dbo.Floors f ON f.FloorId=m.FloorId JOIN dbo.Buildings b ON b.BuildingId=f.BuildingId
    WHERE a.PeriodType='HOUR' AND m.EnergyTypeId=@EnergyTypeId AND (@BuildingId IS NULL OR f.BuildingId=@BuildingId)
      AND a.PeriodStart>=@From AND a.PeriodStart<@To
    GROUP BY b.BuildingName,f.FloorNo,f.FloorName ORDER BY b.BuildingName,f.FloorNo;
END
GO
/* Heatmap: tiêu thụ TB theo (tầng, giờ trong ngày) */
CREATE OR ALTER PROCEDURE dbo.usp_Dash_Heatmap @BuildingId INT=NULL,@EnergyTypeId INT,@From DATETIME2(0),@To DATETIME2(0)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT x.FloorNo,x.FloorName,DATEPART(HOUR,x.PeriodStart) AS HourOfDay,AVG(x.Total) AS AvgValue
    FROM (SELECT f.FloorId,f.FloorNo,f.FloorName,a.PeriodStart,SUM(a.TotalValue) AS Total
          FROM dbo.EnergyAggregates a JOIN dbo.Meters m ON m.MeterId=a.MeterId JOIN dbo.Floors f ON f.FloorId=m.FloorId
          WHERE a.PeriodType='HOUR' AND m.EnergyTypeId=@EnergyTypeId AND (@BuildingId IS NULL OR f.BuildingId=@BuildingId)
            AND a.PeriodStart>=@From AND a.PeriodStart<@To AND a.IsComplete=1
          GROUP BY f.FloorId,f.FloorNo,f.FloorName,a.PeriodStart) x
    GROUP BY x.FloorNo,x.FloorName,DATEPART(HOUR,x.PeriodStart) ORDER BY x.FloorNo,HourOfDay;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Dash_MeterStatus @BuildingId INT=NULL,@EnergyTypeId INT=NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT m.MeterId,m.MeterCode,m.MeterName,f.FloorId,f.FloorName,e.Name AS EnergyName,e.Unit,m.LocX,m.LocY,m.Status AS MeterStatus,m.LastReadingAt,
           lv.LastValue,ISNULL(td.TodayTotal,0) AS TodayTotal,
           (SELECT COUNT(*) FROM dbo.DataAnomalies d WHERE d.MeterId=m.MeterId AND d.Status='OPEN') AS OpenDataAnomalies,
           (SELECT COUNT(*) FROM dbo.ConsumptionAnomalies c WHERE c.MeterId=m.MeterId AND c.Status='NEW') AS NewConsumptionAnomalies,
           CASE WHEN m.Status<>'ACTIVE' THEN 'GREY'
                WHEN EXISTS(SELECT 1 FROM dbo.DataAnomalies d WHERE d.MeterId=m.MeterId AND d.AnomalyType='NO_SIGNAL' AND d.Status='OPEN') THEN 'GREY'
                WHEN EXISTS(SELECT 1 FROM dbo.ConsumptionAnomalies c WHERE c.MeterId=m.MeterId AND c.Status='NEW' AND c.Severity='HIGH') THEN 'RED'
                WHEN EXISTS(SELECT 1 FROM dbo.DataAnomalies d WHERE d.MeterId=m.MeterId AND d.Status='OPEN')
                  OR EXISTS(SELECT 1 FROM dbo.ConsumptionAnomalies c WHERE c.MeterId=m.MeterId AND c.Status='NEW') THEN 'YELLOW'
                ELSE 'GREEN' END AS State
    FROM dbo.Meters m JOIN dbo.Floors f ON f.FloorId=m.FloorId JOIN dbo.EnergyTypes e ON e.EnergyTypeId=m.EnergyTypeId
    OUTER APPLY (SELECT TOP 1 a.TotalValue AS LastValue FROM dbo.EnergyAggregates a WHERE a.MeterId=m.MeterId AND a.PeriodType='HOUR' AND a.IsComplete=1 ORDER BY a.PeriodStart DESC) lv
    OUTER APPLY (SELECT TOP 1 a.TotalValue AS TodayTotal FROM dbo.EnergyAggregates a WHERE a.MeterId=m.MeterId AND a.PeriodType='DAY'
                 AND a.PeriodStart=CAST(CAST(SYSDATETIME() AS DATE) AS DATETIME2(0))) td
    WHERE (@BuildingId IS NULL OR f.BuildingId=@BuildingId) AND (@EnergyTypeId IS NULL OR m.EnergyTypeId=@EnergyTypeId)
    ORDER BY f.FloorNo,m.MeterCode;
END
GO
/* 10.6 Dữ liệu báo cáo - tiêu đề cột tiếng Việt dùng trực tiếp khi xuất Excel/PDF */
CREATE OR ALTER PROCEDURE dbo.usp_Report_Consumption
    @BuildingId INT=NULL,@FloorId INT=NULL,@EnergyTypeId INT,@From DATETIME2(0),@To DATETIME2(0),@Grain VARCHAR(5)='DAY'
AS
BEGIN
    SET NOCOUNT ON;
    IF @To<@From THROW 51001,N'Khoảng thời gian không hợp lệ',1;
    SELECT b.BuildingName AS [Tòa nhà],f.FloorName AS [Tầng],m.MeterCode AS [Mã công tơ],e.Name AS [Loại năng lượng],
           a.PeriodType AS [Chu kỳ],a.PeriodStart AS [Thời điểm],a.TotalValue AS [Tiêu thụ],e.Unit AS [Đơn vị],
           CAST(a.TotalValue*e.PricePerUnit AS DECIMAL(18,0)) AS [Chi phí (VND)],
           CASE WHEN a.IsComplete=1 THEN N'Đầy đủ' ELSE N'Chưa đầy đủ' END AS [Chất lượng dữ liệu]
    FROM dbo.EnergyAggregates a JOIN dbo.Meters m ON m.MeterId=a.MeterId JOIN dbo.Floors f ON f.FloorId=m.FloorId
    JOIN dbo.Buildings b ON b.BuildingId=f.BuildingId JOIN dbo.EnergyTypes e ON e.EnergyTypeId=m.EnergyTypeId
    WHERE a.PeriodType=@Grain AND m.EnergyTypeId=@EnergyTypeId AND a.ValidCount>0
      AND (@BuildingId IS NULL OR f.BuildingId=@BuildingId) AND (@FloorId IS NULL OR m.FloorId=@FloorId)
      AND a.PeriodStart>=@From AND a.PeriodStart<@To
    ORDER BY a.PeriodStart,b.BuildingName,f.FloorNo,m.MeterCode;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Report_Log
    @ReportType VARCHAR(20),@Format VARCHAR(5),@Filters NVARCHAR(300),@RecordCount INT,@FilePath NVARCHAR(300),@UserId INT
AS BEGIN SET NOCOUNT ON;
    INSERT dbo.ReportExports(ReportType,Format,Filters,RecordCount,FilePath,ExportedBy) VALUES(@ReportType,@Format,@Filters,@RecordCount,@FilePath,@UserId); END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Report_History @Top INT=200 AS BEGIN SET NOCOUNT ON;
    SELECT TOP (@Top) r.ExportId,r.ReportType,r.Format,r.Filters,r.RecordCount,r.FilePath,u.FullName AS ExportedByName,r.ExportedAt
    FROM dbo.ReportExports r JOIN dbo.Users u ON u.UserId=r.ExportedBy ORDER BY r.ExportId DESC; END
GO
/* =====================================================================
   99_SeedData.sql - DỮ LIỆU MẪU ĐỂ DEMO TOÀN BỘ 11 USE CASE
   Tài khoản (mật khẩu chung: Admin@123):
     admin   - Quản trị viên | quanly - Quản lý năng lượng | ktv - Kỹ thuật viên | banql - Ban quản lý
   Dữ liệu: 1 tòa nhà, 4 tầng, 8 phòng, 6 công tơ, 42 ngày dữ liệu theo giờ (tính lùi từ hiện tại),
   có cài sẵn lỗi: số âm, nhảy vọt, khuyết dữ liệu, mất tín hiệu, tiêu thụ ngoài giờ, rò rỉ nước.
   Script chạy lại được nhiều lần (bỏ qua nếu đã có dữ liệu).
   ===================================================================== */
USE EnergyPortalDB;
GO
SET NOCOUNT ON;
SET NOCOUNT ON;
IF EXISTS(SELECT 1 FROM dbo.Buildings WHERE BuildingCode='TOA_A') PRINT N'Đã có dữ liệu mẫu - bỏ qua.';
ELSE
BEGIN
/* ---- UC11: người dùng ---- */
INSERT dbo.Users(Username,Email,FullName,PasswordHash,RoleId,Status) VALUES
 (N'admin', N'admin@evn03.local', N'Quản Trị Hệ Thống','PBKDF2$10000$obLD1OX2BxgpOktcbX6PkA==$/riMw9azWo9/PjQCvGPtU03cJ3IVq439Blv7gbRQSKU=',1,'ACTIVE'),
 (N'quanly',N'quanly@evn03.local',N'Nguyễn Quản Lý',   'PBKDF2$10000$obLD1OX2BxgpOktcbX6PkA==$/riMw9azWo9/PjQCvGPtU03cJ3IVq439Blv7gbRQSKU=',2,'ACTIVE'),
 (N'ktv',   N'ktv@evn03.local',   N'Trần Kỹ Thuật',    'PBKDF2$10000$obLD1OX2BxgpOktcbX6PkA==$/riMw9azWo9/PjQCvGPtU03cJ3IVq439Blv7gbRQSKU=',3,'ACTIVE'),
 (N'banql', N'banql@evn03.local', N'Lê Ban Quản Lý',   'PBKDF2$10000$obLD1OX2BxgpOktcbX6PkA==$/riMw9azWo9/PjQCvGPtU03cJ3IVq439Blv7gbRQSKU=',4,'ACTIVE');
DECLARE @admin INT=(SELECT UserId FROM dbo.Users WHERE Username=N'admin');
DECLARE @mgr   INT=(SELECT UserId FROM dbo.Users WHERE Username=N'quanly');

/* ---- UC01: tòa nhà - tầng - phòng - công tơ ---- */
EXEC dbo.usp_Building_Save @BuildingCode='TOA_A',@BuildingName=N'Tòa nhà Văn phòng A',@Address=N'12 Nguyễn Huệ, Quận 1, TP.HCM';
DECLARE @b INT=(SELECT BuildingId FROM dbo.Buildings WHERE BuildingCode='TOA_A');
DECLARE @n INT=1;
WHILE @n<=4
BEGIN
    DECLARE @fname NVARCHAR(50)=N'Tầng '+CAST(@n AS NVARCHAR(5));
    EXEC dbo.usp_Floor_Save @BuildingId=@b,@FloorNo=@n,@FloorName=@fname,@MinX=0,@MinY=0,@MaxX=60,@MaxY=40;
    DECLARE @fid INT=(SELECT FloorId FROM dbo.Floors WHERE BuildingId=@b AND FloorNo=@n);
    DECLARE @c1 VARCHAR(20)='A'+CAST(@n AS VARCHAR(2))+'01',@c2 VARCHAR(20)='A'+CAST(@n AS VARCHAR(2))+'02';
    DECLARE @r1 NVARCHAR(100)=N'Phòng '+@c1,@r2 NVARCHAR(100)=N'Phòng '+@c2;
    EXEC dbo.usp_Room_Save @FloorId=@fid,@RoomCode=@c1,@RoomName=@r1,@MinX=0, @MinY=0,@MaxX=30,@MaxY=20;
    EXEC dbo.usp_Room_Save @FloorId=@fid,@RoomCode=@c2,@RoomName=@r2,@MinX=30,@MinY=0,@MaxX=60,@MaxY=20;
    SET @n+=1;
END
DECLARE @f1 INT=(SELECT FloorId FROM dbo.Floors WHERE BuildingId=@b AND FloorNo=1),@f2 INT=(SELECT FloorId FROM dbo.Floors WHERE BuildingId=@b AND FloorNo=2),
        @f3 INT=(SELECT FloorId FROM dbo.Floors WHERE BuildingId=@b AND FloorNo=3),@f4 INT=(SELECT FloorId FROM dbo.Floors WHERE BuildingId=@b AND FloorNo=4);
DECLARE @a201 INT=(SELECT RoomId FROM dbo.Rooms WHERE RoomCode='A201'),@a102 INT=(SELECT RoomId FROM dbo.Rooms WHERE RoomCode='A102');
EXEC dbo.usp_Meter_Save @MeterCode='E-A-T1-001',@MeterName=N'Điện tổng tầng 1',@EnergyTypeId=1,@Manufacturer=N'Schneider',@Model=N'iEM3250',@SerialNo=N'SN1001',
     @Specification=N'3 pha 380V, 100A',@MaxValuePerInterval=150,@FloorId=@f1,@LocX=30,@LocY=30,@InstallDate='2024-01-10',@UserId=@admin;
EXEC dbo.usp_Meter_Save @MeterCode='E-A-T2-001',@MeterName=N'Điện điều hòa tầng 2',@EnergyTypeId=1,@Manufacturer=N'Schneider',@Model=N'iEM3250',@SerialNo=N'SN1002',
     @Specification=N'3 pha 380V, 100A',@MaxValuePerInterval=150,@FloorId=@f2,@RoomId=@a201,@LocX=10,@LocY=10,@InstallDate='2024-01-10',@UserId=@admin;
EXEC dbo.usp_Meter_Save @MeterCode='E-A-T3-001',@MeterName=N'Điện tổng tầng 3',@EnergyTypeId=1,@Manufacturer=N'ABB',@Model=N'EQ-Meter',@SerialNo=N'SN1003',
     @Specification=N'3 pha 380V, 100A',@MaxValuePerInterval=150,@FloorId=@f3,@LocX=30,@LocY=30,@InstallDate='2024-02-01',@UserId=@admin;
EXEC dbo.usp_Meter_Save @MeterCode='E-A-T4-001',@MeterName=N'Điện tổng tầng 4',@EnergyTypeId=1,@Manufacturer=N'ABB',@Model=N'EQ-Meter',@SerialNo=N'SN1004',
     @Specification=N'3 pha 380V, 100A',@MaxValuePerInterval=150,@FloorId=@f4,@LocX=20,@LocY=25,@InstallDate='2024-02-01',@UserId=@admin;
EXEC dbo.usp_Meter_Save @MeterCode='W-A-T1-001',@MeterName=N'Nước tổng tầng 1',@EnergyTypeId=2,@Manufacturer=N'Itron',@Model=N'Cyble',@SerialNo=N'SN2001',
     @Specification=N'DN50, Q3=25 m3/h',@MaxValuePerInterval=5,@FloorId=@f1,@LocX=50,@LocY=35,@InstallDate='2024-01-10',@UserId=@admin;
EXEC dbo.usp_Meter_Save @MeterCode='G-A-T1-001',@MeterName=N'Gas bếp ăn tầng 1',@EnergyTypeId=3,@Manufacturer=N'Elster',@Model=N'BK-G4',@SerialNo=N'SN3001',
     @Specification=N'G4, 6 m3/h',@MaxValuePerInterval=5,@FloorId=@f1,@RoomId=@a102,@LocX=45,@LocY=10,@InstallDate='2024-03-15',@UserId=@admin;

/* ---- UC02/UC05: 42 ngày dữ liệu theo giờ qua pipeline tiếp nhận ---- */
DECLARE @Now DATETIME2(0)=CAST(DATEADD(HOUR,DATEDIFF(HOUR,'19000101',SYSDATETIME()),'19000101') AS DATETIME2(0));
DECLARE @Today DATETIME2(0)=CAST(CAST(SYSDATETIME() AS DATE) AS DATETIME2(0));
DECLARE @planStart DATETIME2(0)=DATEADD(DAY,-14,@Today);
DECLARE @prof TABLE(Code VARCHAR(30),Base DECIMAL(9,3),Peak DECIMAL(9,3),Noise DECIMAL(9,3),Wk DECIMAL(5,2),Fac DECIMAL(5,3));
INSERT @prof VALUES('E-A-T1-001',6,30,1.5,0.40,1.000),('E-A-T2-001',8,45,2.0,0.35,0.940),('E-A-T3-001',7,38,1.8,0.35,0.920),
                   ('E-A-T4-001',6,32,1.5,0.40,1.000),('W-A-T1-001',0.2,1.2,0.08,0.50,1.000),('G-A-T1-001',0.1,0.9,0.05,0.30,1.000);
DECLARE @bt dbo.TelemetryBatchType;
;WITH k AS (SELECT TOP (1008) CAST(ROW_NUMBER() OVER(ORDER BY (SELECT NULL)) AS INT) AS k FROM sys.all_columns a CROSS JOIN sys.all_columns b)
INSERT @bt(MeterCode,ReadingTime,ReadingValue)
SELECT p.Code,t.ts,v.val
FROM @prof p CROSS JOIN k
CROSS APPLY (SELECT CAST(DATEADD(HOUR,-k.k,@Now) AS DATETIME2(0)) AS ts) t
CROSS APPLY (SELECT DATEPART(HOUR,t.ts) AS hr,CASE WHEN dbo.fn_DayType(CAST(t.ts AS DATE))='WEEKEND' THEN p.Wk ELSE 1 END AS wk) h
CROSS APPLY (SELECT CASE WHEN h.hr BETWEEN 8 AND 17 THEN 1.0 WHEN h.hr IN (7,18) THEN 0.5 WHEN h.hr BETWEEN 19 AND 21 THEN 0.15 ELSE 0 END
                    *CASE WHEN h.hr=12 THEN 0.85 ELSE 1.0 END AS curve) c
CROSS APPLY (SELECT (p.Base+(p.Peak-p.Base)*c.curve*h.wk+p.Noise*((CHECKSUM(p.Code,k.k)%2001)/2000.0))*CASE WHEN t.ts>=@planStart THEN p.Fac ELSE 1 END AS rawv) r
CROSS APPLY (SELECT CAST(CASE WHEN r.rawv<0 THEN 0 ELSE r.rawv END AS DECIMAL(18,3)) AS val) v
WHERE NOT (p.Code='G-A-T1-001' AND k.k<=10)                                                                            -- mất tín hiệu 10 giờ gần nhất
  AND NOT (p.Code='E-A-T3-001' AND t.ts>=DATEADD(HOUR,9,DATEADD(DAY,-1,@Today)) AND t.ts<=DATEADD(HOUR,11,DATEADD(DAY,-1,@Today))); -- khuyết 3 giờ hôm qua
UPDATE @bt SET ReadingValue=28   WHERE MeterCode='E-A-T1-001' AND ReadingTime=DATEADD(HOUR,2,DATEADD(DAY,-2,@Today));   -- tiêu thụ ngoài giờ
UPDATE @bt SET ReadingValue=26   WHERE MeterCode='E-A-T1-001' AND ReadingTime=DATEADD(HOUR,3,DATEADD(DAY,-2,@Today));
UPDATE @bt SET ReadingValue=380  WHERE MeterCode='E-A-T4-001' AND ReadingTime=DATEADD(HOUR,14,DATEADD(DAY,-3,@Today));  -- nhảy vọt phi lý
UPDATE @bt SET ReadingValue=-5   WHERE MeterCode='E-A-T2-001' AND ReadingTime=DATEADD(HOUR,10,DATEADD(DAY,-2,@Today));  -- chỉ số âm
UPDATE @bt SET ReadingValue=2.2  WHERE MeterCode='W-A-T1-001' AND ReadingTime=DATEADD(HOUR,3,DATEADD(DAY,-1,@Today));   -- rò rỉ nước ban đêm
DECLARE @acc INT,@rej INT,@anom INT;
EXEC dbo.usp_Telemetry_IngestBatch @bt,'IOT',NULL,@acc OUTPUT,@rej OUTPUT,@anom OUTPUT,@Quiet=1;
PRINT N'Đã nạp '+CAST(@acc AS NVARCHAR(10))+N' bản ghi, từ chối '+CAST(@rej AS NVARCHAR(10))+N', bất thường dữ liệu '+CAST(@anom AS NVARCHAR(10));

/* ---- UC03: định mức ---- */
DECLARE @from DATE=DATEADD(DAY,-60,CAST(SYSDATETIME() AS DATE));
EXEC dbo.usp_Quota_Save @QuotaCode='DM-001',@BuildingId=@b,@EnergyTypeId=1,@PeriodType='DAY', @QuotaValue=2000,@WarningPercent=80,@EffectiveFrom=@from,@UserId=@mgr,@Note=N'Định mức điện cả tòa nhà theo ngày';
EXEC dbo.usp_Quota_Save @QuotaCode='DM-002',@BuildingId=@b,@FloorId=@f4,@EnergyTypeId=1,@PeriodType='DAY',@QuotaValue=400,@WarningPercent=85,@EffectiveFrom=@from,@UserId=@mgr,@Note=N'Định mức tầng 4';
EXEC dbo.usp_Quota_Save @QuotaCode='DM-003',@BuildingId=@b,@FloorId=@f2,@EnergyTypeId=1,@PeriodType='HOUR',@QuotaValue=40,@WarningPercent=90,@EffectiveFrom=@from,
     @TimeFrom='08:00:00',@TimeTo='17:59:59',@UserId=@mgr,@Note=N'Định mức giờ hành chính tầng 2';
EXEC dbo.usp_Quota_Save @QuotaCode='DM-004',@BuildingId=@b,@EnergyTypeId=2,@PeriodType='DAY',@QuotaValue=20,@WarningPercent=80,@EffectiveFrom=@from,@UserId=@mgr,@Note=N'Định mức nước';

/* ---- UC04 / UC06: giám sát & phân tích ---- */
EXEC dbo.usp_Monitor_Scan @LookbackDays=3;
EXEC dbo.usp_CA_Scan @UserId=@mgr;

/* ---- UC08/UC09: kế hoạch tiết kiệm & KPI ---- */
DECLARE @ps DATE=DATEADD(DAY,-14,CAST(SYSDATETIME() AS DATE)),@pe DATE=DATEADD(DAY,30,CAST(SYSDATETIME() AS DATE));
EXEC dbo.usp_Plan_Save @PlanCode='KH-001',@PlanName=N'Giảm 10% điện điều hòa tầng 2',@BuildingId=@b,@FloorId=@f2,@EnergyTypeId=1,@TargetPercent=10,@StartDate=@ps,@EndDate=@pe,@UserId=@mgr,@Description=N'Điều chỉnh nhiệt độ và lịch chạy điều hòa';
EXEC dbo.usp_Plan_Save @PlanCode='KH-002',@PlanName=N'Giảm 5% điện tầng 3',@BuildingId=@b,@FloorId=@f3,@EnergyTypeId=1,@TargetPercent=5,@StartDate=@ps,@EndDate=@pe,@UserId=@mgr,@Description=N'Tắt thiết bị ngoài giờ';
DECLARE @p1 INT=(SELECT PlanId FROM dbo.SavingPlans WHERE PlanCode='KH-001'),@p2 INT=(SELECT PlanId FROM dbo.SavingPlans WHERE PlanCode='KH-002');
EXEC dbo.usp_Solution_Save @PlanId=@p1,@SolutionName=N'Đặt nhiệt độ điều hòa 26°C',@ExpectedSavingPercent=6,@Status='IN_PROGRESS',@AssignedTo=N'Tổ kỹ thuật';
EXEC dbo.usp_Solution_Save @PlanId=@p1,@SolutionName=N'Tắt điều hòa sau 18h',@ExpectedSavingPercent=4,@Status='PLANNED',@AssignedTo=N'Bảo vệ tòa nhà';
EXEC dbo.usp_Solution_Save @PlanId=@p2,@SolutionName=N'Tắt máy tính, đèn ngoài giờ',@ExpectedSavingPercent=5,@Status='DONE',@AssignedTo=N'Quản lý tầng 3';
EXEC dbo.usp_KPI_Calculate @PlanId=@p1,@UserId=@mgr;
EXEC dbo.usp_KPI_Calculate @PlanId=@p2,@UserId=@mgr;
PRINT N'Hoàn tất dữ liệu mẫu.';
END
GO
SELECT TOP 5 ToEmail, Subject, Body 
FROM dbo.EmailOutbox 
ORDER BY EmailId DESC;
SELECT Username, Email, ActivationToken, Status 
FROM dbo.Users 
WHERE Username = 'abc';

/* Web adapter: nhận danh sách RawId dạng JSON, sau đó gọi lại thủ tục TVP gốc.
   Không thay đổi logic Preview/Apply và vẫn giữ transaction + Audit Log của UC07. */
CREATE OR ALTER PROCEDURE dbo.usp_Transform_PreviewJson
    @TargetsJson NVARCHAR(MAX), @MethodCode VARCHAR(20), @Window INT=2
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@TargetsJson)<>1 THROW 50730,N'Danh sách RawId phải là JSON hợp lệ',1;
    DECLARE @Targets dbo.IdListType;
    INSERT @Targets(Id)
    SELECT DISTINCT TRY_CONVERT(BIGINT,[value])
    FROM OPENJSON(@TargetsJson)
    WHERE TRY_CONVERT(BIGINT,[value]) IS NOT NULL AND TRY_CONVERT(BIGINT,[value])>0;
    IF NOT EXISTS(SELECT 1 FROM @Targets) THROW 50731,N'Chưa có RawId hợp lệ để xem trước',1;
    EXEC dbo.usp_Transform_Preview @Targets=@Targets,@MethodCode=@MethodCode,@Window=@Window;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Transform_ApplyJson
    @TargetsJson NVARCHAR(MAX), @MethodCode VARCHAR(20), @Window INT=2,
    @Reason NVARCHAR(500), @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@TargetsJson)<>1 THROW 50730,N'Danh sách RawId phải là JSON hợp lệ',1;
    DECLARE @Targets dbo.IdListType;
    INSERT @Targets(Id)
    SELECT DISTINCT TRY_CONVERT(BIGINT,[value])
    FROM OPENJSON(@TargetsJson)
    WHERE TRY_CONVERT(BIGINT,[value]) IS NOT NULL AND TRY_CONVERT(BIGINT,[value])>0;
    IF NOT EXISTS(SELECT 1 FROM @Targets) THROW 50731,N'Chưa có RawId hợp lệ để áp dụng',1;
    EXEC dbo.usp_Transform_Apply @Targets=@Targets,@MethodCode=@MethodCode,@Window=@Window,@Reason=@Reason,@UserId=@UserId;
END
GO
