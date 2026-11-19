"""Bearer-secret auth for /v1 (shared with Phoenix; private network only)."""

import hmac

from fastapi import HTTPException, Request

from .config import Settings


def bearer_dependency(settings: Settings):
    expected = b"Bearer " + settings.secret.get_secret_value().encode()

    def require_bearer(request: Request) -> None:
        given = request.headers.get("authorization", "").encode()
        if not hmac.compare_digest(given, expected):
            raise HTTPException(
                status_code=401,
                detail={"error": "unauthorized"},
                headers={"WWW-Authenticate": "Bearer"},
            )

    return require_bearer
