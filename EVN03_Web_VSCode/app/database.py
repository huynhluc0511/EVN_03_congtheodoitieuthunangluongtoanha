import os
from datetime import date, datetime
from decimal import Decimal
from dotenv import load_dotenv
import pyodbc

load_dotenv()

def connection_string():
    driver = os.getenv("DB_DRIVER", "ODBC Driver 18 for SQL Server")
    server = os.getenv("DB_SERVER", "localhost")
    database = os.getenv("DB_NAME", "EnergyPortalDB")
    trusted = os.getenv("DB_TRUSTED_CONNECTION", "yes").lower() in ("yes", "true", "1")
    encrypt = os.getenv("DB_ENCRYPT", "no")
    trust_cert = os.getenv("DB_TRUST_SERVER_CERTIFICATE", "yes")
    parts = [
        f"DRIVER={{{driver}}}", f"SERVER={server}", f"DATABASE={database}",
        f"Encrypt={encrypt}", f"TrustServerCertificate={trust_cert}", "Connection Timeout=15"
    ]
    if trusted:
        parts.append("Trusted_Connection=yes")
    else:
        parts += [f"UID={os.getenv('DB_USERNAME','')}", f"PWD={os.getenv('DB_PASSWORD','')}"]
    return ";".join(parts) + ";"

def get_connection():
    return pyodbc.connect(connection_string(), timeout=15)

def json_value(value):
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, bytes):
        return value.hex()
    return value

def execute_procedure(proc_name: str, params: dict | None = None):
    """Chỉ gọi stored procedure nằm trong allowlist; giá trị truyền bằng parameter binding."""
    from app.procedure_catalog import ALLOWED_PROCEDURES
    if proc_name not in ALLOWED_PROCEDURES:
        raise ValueError("Stored procedure không nằm trong danh sách được phép.")
    params = params or {}
    for key in params:
        if not key.replace("_", "").isalnum() or not key[0].isalpha():
            raise ValueError(f"Tên tham số không hợp lệ: {key}")
    assignments = ", ".join(f"@{key}=?" for key in params)
    sql = f"EXEC dbo.[{proc_name}]" + (f" {assignments}" if assignments else "")
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(sql, list(params.values()))
        result_sets = []
        while True:
            if cur.description:
                columns = [c[0] for c in cur.description]
                rows = [{columns[i]: json_value(v) for i, v in enumerate(row)} for row in cur.fetchall()]
                result_sets.append(rows)
            if not cur.nextset():
                break
        conn.commit()
        return result_sets

def test_connection():
    with get_connection() as conn:
        row = conn.cursor().execute("SELECT DB_NAME(), @@VERSION").fetchone()
        return {"database": row[0], "version": row[1].splitlines()[0]}
