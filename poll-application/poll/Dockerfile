FROM python:3.14-slim@sha256:cd89c30eda26ee911a4611b18680086e0ea42e6f5f8cbe653d07fa7958c9cec8

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN useradd --system --uid 10001 app
USER 10001

EXPOSE 80

CMD ["gunicorn", "--workers", "2", "--bind", "0.0.0.0:80", "wsgi:app"]
