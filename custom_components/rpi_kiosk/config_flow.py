"""Config flow for Raspberry Pi Kiosk integration."""
import logging
import voluptuous as vol
import aiohttp
import async_timeout

from homeassistant import config_entries
from homeassistant.core import callback

from .const import DOMAIN, CONF_HOST, CONF_PORT, CONF_PIN, DEFAULT_PORT

_LOGGER = logging.getLogger(__name__)


class KioskConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    """Handle a config flow for Raspberry Pi Kiosk."""

    VERSION = 1

    async def async_step_user(self, user_input=None):
        """Handle the initial step."""
        errors = {}

        if user_input is not None:
            host = user_input[CONF_HOST].strip()
            port = user_input.get(CONF_PORT, DEFAULT_PORT)
            pin = user_input.get(CONF_PIN, "").strip()

            # Test connection
            try:
                url = f"http://{host}:{port}/api/status"
                async with async_timeout.timeout(5):
                    async with aiohttp.ClientSession() as session:
                        async with session.get(url) as resp:
                            if resp.status == 200:
                                data = await resp.json()
                                device_name = data.get("config", {}).get("mqtt", {}).get("device_name", f"RPi Kiosk ({host})")
                                return self.async_create_entry(
                                    title=device_name,
                                    data={
                                        CONF_HOST: host,
                                        CONF_PORT: port,
                                        CONF_PIN: pin,
                                    },
                                )
                            errors["base"] = "cannot_connect"
            except Exception:
                errors["base"] = "cannot_connect"

        schema = vol.Schema({
            vol.Required(CONF_HOST, default=""): str,
            vol.Optional(CONF_PORT, default=DEFAULT_PORT): int,
            vol.Optional(CONF_PIN, default=""): str,
        })

        return self.async_show_form(
            step_id="user",
            data_schema=schema,
            errors=errors,
        )
