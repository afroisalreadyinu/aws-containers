import os
from flask import Flask

app = Flask('env-printer-app')

PAGE = """
<html>
  <body>
    Hostname: {HOST}
  </body>
</html>
"""

@app.route("/")
def index():
    return PAGE.format(**os.environ)

app.run(host='0.0.0.0', port=8080)
