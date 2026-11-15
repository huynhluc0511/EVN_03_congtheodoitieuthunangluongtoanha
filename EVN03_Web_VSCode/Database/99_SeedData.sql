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
