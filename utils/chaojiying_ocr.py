import base64
import logging
import re
from hashlib import md5
from typing import Optional

import requests


class ChaojiyingOCR:
    """Chaojiying OCR client for text-click captcha."""

    API_URL = "http://upload.chaojiying.net/Upload/Processing.php"

    def __init__(
        self,
        username: str,
        password: str,
        soft_id: str,
        codetype: int = 9800,
    ):
        self.username = username
        self.password_md5 = md5(password.encode("utf-8")).hexdigest()
        self.soft_id = str(soft_id)
        self.codetype = int(codetype)
        self.headers = {
            "Connection": "Keep-Alive",
            "User-Agent": "Mozilla/4.0 (compatible; MSIE 8.0; Windows NT 5.1; Trident/4.0)",
        }

    @staticmethod
    def _normalize_base64(base64_str: str) -> str:
        raw = str(base64_str or "").strip()
        if "," in raw and raw.lower().startswith("data:"):
            raw = raw.split(",", 1)[1]
        return re.sub(r"\s+", "", raw)

    @staticmethod
    def _decode_char(char: str) -> str:
        text = str(char or "")
        if "\\u" not in text:
            return text
        try:
            return text.encode("utf-8").decode("unicode_escape")
        except UnicodeDecodeError:
            return text

    @classmethod
    def _parse_pic_str(cls, pic_str: str) -> list[dict]:
        coordinates = []
        for chunk in str(pic_str or "").split("|"):
            parts = chunk.split(",")
            if len(parts) < 3:
                continue
            try:
                coordinates.append(
                    {
                        "text": cls._decode_char(parts[0]),
                        "x": int(float(parts[1])),
                        "y": int(float(parts[2])),
                    }
                )
            except ValueError:
                logging.debug("Skip unparsable Chaojiying OCR chunk: %s", chunk)
        return coordinates

    def recognize_textclick(self, img_data: bytes) -> Optional[dict]:
        b64_data = base64.b64encode(img_data).decode("ascii")
        params = {
            "user": self.username,
            "pass2": self.password_md5,
            "softid": self.soft_id,
            "codetype": self.codetype,
            "file_base64": self._normalize_base64(b64_data),
        }
        try:
            response = requests.post(
                self.API_URL,
                data=params,
                headers=self.headers,
                timeout=30,
            )
            result = response.json()
        except Exception as e:
            logging.debug("Chaojiying OCR request failed: %s", e)
            return None

        logging.debug("Chaojiying OCR response: %s", result)
        if int(result.get("err_no") or 0) != 0:
            logging.debug(
                "Chaojiying OCR failed: err_no=%s err_str=%s",
                result.get("err_no"),
                result.get("err_str"),
            )
            return None

        coordinates = self._parse_pic_str(result.get("pic_str", ""))
        if not coordinates:
            logging.debug("Chaojiying OCR returned no coordinates")
            return None

        return {
            "text": "".join(str(item.get("text") or "") for item in coordinates),
            "coordinates": coordinates,
            "raw_result": result,
        }
