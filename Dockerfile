FROM python:3.14
RUN apt-get update && apt-get install -y git 
RUN apt-get install -y docker.io && rm -rf /var/lib/apt/lists/*
COPY ./requirements.txt .
COPY ./task_management_app/runner.py .
RUN pip install --no-cache-dir -r requirements.txt
CMD ["bash", "-c",  "git config --global --add safe.directory /source/.git && git clone /source task_management_app && cd /task_management_app && git checkout \"$COMMIT_ID\" && python3 runner.py"]