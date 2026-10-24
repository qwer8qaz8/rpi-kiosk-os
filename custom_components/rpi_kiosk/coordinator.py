"""DataUpdateCoordinator for Raspberry Pi Kiosk."""
import logging
from datetime import timedelta
import aiohttp
import async_timeout

from homeassistant.core import HomeAssistant
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed

from .const import DOMAIN

_LOGGER = logging.getLogger(__name__)


class KioskDataUpdateCoordinator(DataUpdateCoordinator):
    """Class to manage fetching kiosk data from the REST API."""

    def __init__(self, hass: HomeAssistant, host: str, port: int, pin: str = ""):
        """Initialize the coordinator."""
        self.host = host
        self.port = port
        self.pin = pin
        self.base_url = f"http://{host}:{port}"
        
        super().__init__(
            hass,
            _LOGGER,
            name=f"RPi Kiosk ({host})",
            update_interval=timedelta(seconds=10),
        )

    async def _async_update_data(self):
        """Fetch data from Kiosk REST endpoint."""
        url = f"{self.base_url}/api/status"
        try:
            async with async_timeout.timeout(6):
                async with aiohttp.ClientSession() as session:
                    headers = {}
                    if self.pin:
                        headers["X-Kiosk-Pin"] = self.pin
                    async with session.get(url, headers=headers) as response:
                        if response.status != 200:
                            raise UpdateFailed(f"Error communicating with kiosk: HTTP {response.status}")
                        return await response.json()
        except Exception as err:
            raise UpdateFailed(f"Connection failed: {err}") from err

    async def async_send_command(self, endpoint: str, data: dict = None):
        """Send a POST command to the kiosk API."""
        url = f"{self.base_url}/api/{endpoint}"
        headers = {}
        if self.pin:
            headers["X-Kiosk-Pin"] = self.pin
        async with async_timeout.timeout(10):
            async with aiohttp.ClientSession() as session:
                async with session.post(url, json=data or {}, headers=headers) as response:
                    return await response.json()
