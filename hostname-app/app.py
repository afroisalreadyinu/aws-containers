import os
from flask import Flask, render_template_string

app = Flask('env-printer-app')

PAGE = """
<html>
  <body>
   <b>Hostname: {{ hostname }} </b>
  </body>
</html>
"""

@app.route("/")
def index():
    return render_template_string(PAGE, hostname=os.environ.get('HOSTNAME', 'not available'))

app.run(host='0.0.0.0', port=8080)
