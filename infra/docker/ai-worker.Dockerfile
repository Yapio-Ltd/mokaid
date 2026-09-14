# --- Shared Python runtime: immutable base plus distro security fixes ---
FROM python:3.12-slim@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea AS python-runtime

# Apply signed Debian 13 updates to the affected packages in this base.
# Minimum-version checks fail closed if a stale mirror lacks a required fix.
RUN apt-get update \
    && apt-get install -y --no-install-recommends --only-upgrade \
       gzip libpcre2-8-0 libsqlite3-0 perl-base \
    && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' gzip)" ge '1.13-1+deb13u1' \
    && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' libpcre2-8-0)" ge '10.46-1~deb13u2' \
    && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' libsqlite3-0)" ge '3.46.1-7+deb13u2' \
    && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' perl-base)" ge '5.40.1-6+deb13u1' \
    && rm -rf /var/lib/apt/lists/*

# --- Build stage ---
FROM python-runtime AS build

WORKDIR /app

COPY apps/ai-worker/requirements.txt ./
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# --- Runtime stage ---
FROM python-runtime AS runtime

RUN useradd --create-home mokaid
WORKDIR /app

COPY --from=build /install /usr/local
COPY --chown=mokaid:mokaid apps/ai-worker/app ./app

# Installation tooling is not used by the worker at runtime. Remove its own
# dependency tree after the build, while retaining all application packages.
RUN python -m pip uninstall --yes pip \
    && python -c "import importlib.util; assert importlib.util.find_spec('pip') is None" \
    && ! command -v pip && ! command -v pip3

USER mokaid
EXPOSE 8100

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8100"]
