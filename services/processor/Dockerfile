# One image for the stream processor and the migrate, finalize and aggregate jobs (RUN_MODE picks the role).
# Build from the repository root so the SQL migrations are included:
#   docker build -f services/processor/Dockerfile -t processor .
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    MIGRATIONS_DIR=/app/db/migrations

WORKDIR /app

COPY services/processor/requirements.txt ./requirements.txt
RUN pip install -r requirements.txt

COPY services/processor/roadride ./roadride
COPY db/migrations ./db/migrations

RUN useradd --system --uid 10001 app
USER 10001

CMD ["python", "-m", "roadride"]
