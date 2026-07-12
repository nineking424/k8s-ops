FROM python:3.12-slim

# tapo: Tapo P110 제어 라이브러리(Rust 기반 wheel)
RUN pip install --no-cache-dir tapo

WORKDIR /app
COPY watchdog.py .

# -u: stdout 버퍼링 끔 → docker logs 즉시 반영
CMD ["python", "-u", "watchdog.py"]
