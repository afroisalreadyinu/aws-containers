import os
from flask import Flask, render_template_string
import requests

app = Flask('hostname-app')

INDEX = """
<html>
  <body>
   <b>Hostname: {{ hostname }} </b>
  </body>
</html>
"""

RANDOM_QUOTE = """
<html>
  <body>
   <p>{{ quote }}</p>
   <p>{{ author }}</p>
  </body>
</html>
"""

@app.route("/")
def index():
    return render_template_string(INDEX, hostname=os.environ.get('HOSTNAME', 'not available'))

@app.route("/random-quote/")
def random_quote():
    try:
        result = requests.get("http://random-quote.local:8080/").json()
    except:
        result = {"quote": "Service not available", "author": ""}
    return render_template_string(RANDOM_QUOTE, **result)


app.run(host='0.0.0.0', port=8080)
