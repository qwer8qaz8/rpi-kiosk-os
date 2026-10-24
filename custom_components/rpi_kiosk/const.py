"""Constants for the Raspberry Pi Kiosk integration."""

DOMAIN = "rpi_kiosk"
DEFAULT_NAME = "Raspberry Pi Kiosk"
DEFAULT_PORT = 8080

CONF_HOST = "host"
CONF_PORT = "port"
CONF_PIN = "pin"

PLATFORMS = [
    "switch",
    "number",
    "button",
    "sensor",
    "camera",
]
