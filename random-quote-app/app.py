import json
import random
from flask import Flask, jsonify

app = Flask('random-quote-app')

with open("quotes.json", 'r') as quotes_file:
    quotes = json.loads(quotes_file.read())

@app.route("/")
def index():
    quote = random.choice(quotes)
    return jsonify(quote=quote['en'], author=quote['author'])

app.run(host='0.0.0.0', port=8080)
