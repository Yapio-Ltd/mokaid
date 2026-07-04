# --- Build stage ---
FROM python:3.12-slim AS build

WORKDIR /app

COPY apps/ai-worker/requirements.txt ./
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# --- Runtime stage ---
FROM python:3.12-slim AS runtime

RUN useradd --create-home mokaid
WORKDIR /app

COPY --from=build /install /usr/local
COPY --chown=mokaid:mokaid apps/ai-worker/app ./app

USER mokaid
EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
