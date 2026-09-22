FROM python:3.12-slim
WORKDIR /app
COPY server.py .
# site/ is mounted at runtime (compose.yaml) so a fresh clone is picked up
# without rebuilding the image. Still copy a stub so the image works standalone.
RUN mkdir -p /app/site
EXPOSE 8080 8443
CMD ["python3", "server.py"]
