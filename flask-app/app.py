from flask import Flask, render_template_string
import requests
from datetime import datetime
import pytz

app = Flask(__name__)

LAT = 42.95696831069287
LON = -78.83224271823022

GRID_API_URL = f"https://api.weather.gov/points/{LAT},{LON}"

# Constants for the Heat Index formula
C1 = -42.379
C2 = 2.04901523
C3 = 10.14333127
C4 = -0.22475541
C5 = -6.83783e-3
C6 = -5.481717e-2
C7 = 1.22874e-3
C8 = 8.5282e-4
C9 = -1.99e-6

def calculate_wind_chill(temp_f, wind_speed_mph):
    if temp_f is None or wind_speed_mph is None or wind_speed_mph < 3:
        return None  
    wind_chill = 35.74 + 0.6215 * temp_f - 35.75 * (wind_speed_mph ** 0.16) + 0.4275 * temp_f * (wind_speed_mph ** 0.16)
    return round(wind_chill)

def calculate_heat_index(temp_f, humidity):
    if temp_f is None or humidity is None:
        return None  
    H = humidity / 100.0
    HI = (C1 + C2 * temp_f + C3 * H + C4 * temp_f * H +
          C5 * temp_f**2 + C6 * H**2 + C7 * temp_f**2 * H +
          C8 * temp_f * H**2 + C9 * temp_f**2 * H**2)
    return round(HI)

def get_hourly_forecast():
    try:
        response = requests.get(GRID_API_URL)
        response.raise_for_status()
        grid_data = response.json()
        office = grid_data['properties']['gridId']
        grid_x = grid_data['properties']['gridX']
        grid_y = grid_data['properties']['gridY']
        forecast_url = f"https://api.weather.gov/gridpoints/{office}/{grid_x},{grid_y}/forecast/hourly"
        forecast_response = requests.get(forecast_url)
        forecast_response.raise_for_status()
        forecast_data = forecast_response.json()
        return forecast_data['properties']['periods'][:24]
    except Exception as e:
        print(f"Error fetching forecast data: {e}")
        return []

@app.route("/")
def home():
    try:
        hourly_forecast = get_hourly_forecast()
        est = pytz.timezone("America/New_York")
        current_hour = datetime.now(est).hour
        theme = "dark" if current_hour >= 19 or current_hour < 6 else "light"
    except Exception as e:
        return f"Error fetching weather data: {e}"

    def get_value(value, round_to_int=False):
        if isinstance(value, dict) and 'value' in value:
            val = value['value']
            return round(val) if round_to_int and val is not None else val
        if isinstance(value, str):
            return value.replace("\n", " ").strip()
        return value

    def format_time(start_time, is_first_row=False):
        dt = datetime.fromisoformat(start_time)
        time_str = dt.strftime("%I %p").lstrip("0")  
        date_str = dt.strftime("%m/%d")
        return f"{date_str}<br>{time_str}" if is_first_row or dt.hour == 0 else time_str  

    chart_labels = []
    chart_real_feel = []

    for period in hourly_forecast:
        temp_f = get_value(period.get('temperature'))
        humidity = get_value(period.get('relativeHumidity'))
        wind_speed = get_value(period.get('windSpeed'))
        wind_speed_mph = int(wind_speed.split()[0]) if wind_speed and wind_speed.split()[0].isdigit() else None
        dewpoint_c = get_value(period.get('dewpoint'))
        
        dewpoint_f = round((dewpoint_c * 9/5) + 32) if dewpoint_c is not None else None
        
        wind_chill = calculate_wind_chill(temp_f, wind_speed_mph)
        heat_index = calculate_heat_index(temp_f, humidity)

        if wind_chill is not None and heat_index is not None:
            real_feel = round((wind_chill + heat_index) / 2)
        elif wind_chill is not None:
            real_feel = wind_chill
        elif heat_index is not None:
            real_feel = heat_index
        else:
            real_feel = temp_f

        period['realFeel'] = f"{real_feel}°F"
        period['windChill'] = f"{wind_chill}°F" if wind_chill is not None else ""
        period['heatIndex'] = f"{heat_index}°F" if heat_index is not None else ""
        period['dewpoint'] = f"{dewpoint_f}°F" if dewpoint_f is not None else ""

        period['windSpeed'] = wind_speed.replace("&nbsp;", " ") if wind_speed else ""  
        period['precipitationProbability'] = get_value(period.get('probabilityOfPrecipitation'), round_to_int=True)

        chart_labels.append(format_time(period['startTime']))
        chart_real_feel.append(real_feel)

    html_template = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Buffalo, NY 24-Hour Weather Forecast</title>
        <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
        <style>
            body {
                font-family: Arial, sans-serif;
                text-align: center;
                padding: 20px;
                transition: background-color 0.5s ease, color 0.5s ease;
            }
            .light { background-color: #f0f8ff; color: #333; }
            .dark { background-color: #1a1a2e; color: #f5f5f5; }
            .container {
                padding: 20px; border-radius: 10px; display: inline-block;
            }
            table {
                margin-top: 20px; width: 100%; border-collapse: collapse;
            }
            th, td {
                padding: 8px; border: 1px solid #ddd; text-align: left;
            }
            th { background-color: #f2f2f2; }
            .time-column { white-space: nowrap; width: 150px; }
            canvas { max-width: 90%; margin: auto; }
        </style>
    </head>
    <body class="{{ theme }}">
        <div class="container">
            <h1>24-Hour Weather Forecast for Buffalo, NY</h1>
            <canvas id="realFeelChart"></canvas>
            <script>
                const ctx = document.getElementById('realFeelChart').getContext('2d');
                new Chart(ctx, {
                    type: 'line',
                    data: {
                        labels: {{ chart_labels | tojson }},
                        datasets: [{
                            label: 'Real Feel (°F)',
                            data: {{ chart_real_feel | tojson }},
                            borderColor: 'rgb(75, 192, 192)',
                            backgroundColor: 'rgba(75, 192, 192, 0.2)',
                            borderWidth: 2
                        }]
                    },
                    options: {
                        responsive: true,
                        scales: {
                            y: {
                                beginAtZero: false
                            }
                        }
                    }
                });
            </script>
            <table>
                <tr>
                    <th class="time-column">Time</th>
                    <th>Temperature</th>
                    <th>Dewpoint</th>
                    <th>Real Feel</th>
                    <th>Wind Chill</th>
                    <th>Heat Index</th>
                    <th>Wind</th>
                    <th>Precipitation</th>
                    <th>Relative Humidity</th>
                </tr>
                {% for period in hourly_forecast %}
                <tr>
                    <td class="time-column">{{ format_time(period.startTime, loop.first) | safe }}</td>
                    <td>{{ get_value(period.temperature) }}°F</td>
                    <td>{{ period.dewpoint }}</td>
                    <td>{{ period.realFeel }}</td>
                    <td>{{ period.windChill }}</td>
                    <td>{{ period.heatIndex }}</td>
                    <td>{{ period.windSpeed | safe }}</td>
                    <td>{{ get_value(period.probabilityOfPrecipitation) }}%</td>
                    <td>{{ get_value(period.relativeHumidity) }}%</td>
                </tr>
                {% endfor %}
            </table>
        </div>
    </body>
    </html>
    """
    return render_template_string(html_template, hourly_forecast=hourly_forecast, theme=theme, format_time=format_time, get_value=get_value, chart_labels=chart_labels, chart_real_feel=chart_real_feel)

if __name__ == "__main__":
    app.run(debug=True)
