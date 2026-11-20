# Read API image. Build context is this folder:
#   docker build -t read-api services/read-api
# Listens on 8000: a non-root user can't bind ports below 1024. Terraform's ingress target_port is 8000.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt ./requirements.txt
RUN pip install -r requirements.txt

COPY app ./app

RUN useradd --system --uid 10001 api
USER 10001

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--no-server-header"]
