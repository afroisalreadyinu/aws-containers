FROM python:3-alpine3.7

ADD app.py /app.py
ADD https://raw.githubusercontent.com/skolakoda/programming-quotes/master/src/data/quotes.json /quotes.json

RUN pip3 install flask

CMD ["python3", "/app.py"]
