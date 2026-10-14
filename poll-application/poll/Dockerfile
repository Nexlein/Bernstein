FROM python:3.14-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN useradd --system --uid 10001 app
USER 10001

EXPOSE 80

CMD ["gunicorn", "--workers", "2", "--bind", "0.0.0.0:80", "wsgi:app"]
