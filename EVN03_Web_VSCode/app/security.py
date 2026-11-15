import base64, hashlib, hmac
from fastapi import Request
from starlette.responses import RedirectResponse

def verify_password(password: str, stored: str) -> bool:
    # Tương thích đúng định dạng PBKDF2$iterations$salt$hash của PasswordHasher.cs trong ZIP.
    try:
        kind, iterations, salt_b64, expected_b64 = stored.split("$")
        if kind != "PBKDF2":
            return False
        salt = base64.b64decode(salt_b64)
        expected = base64.b64decode(expected_b64)
        actual = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, int(iterations), dklen=32)
        return hmac.compare_digest(actual, expected)
    except Exception:
        return False

def require_user(request: Request):
    user = request.session.get("user")
    if not user:
        return None
    return user

def login_redirect():
    return RedirectResponse("/login", status_code=303)
