import os
from flask import Flask, render_template_string

app = Flask('env-printer-app')

PAGE = """
<html>
  <body>
   Environment:
   <ul>
    {% for key,value in environment %}
    <li>{{ key }}: {{ value }} </li>
    {% endfor %}
   </ul>
  </body>
</html>
"""

@app.route("/")
def index():
    return render_template_string(PAGE, environment=os.environ.items())

app.run(host='0.0.0.0', port=8080)
