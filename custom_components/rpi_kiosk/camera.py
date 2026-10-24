"""Camera platform for Raspberry Pi Kiosk."""
import logging
import aiohttp
import async_timeout

from homeassistant.components.camera import Camera
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.entity import DeviceInfo

from .const import DOMAIN
from .coordinator import KioskDataUpdateCoordinator

_LOGGER = logging.getLogger(__name__)


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    """Set up the Kiosk camera entities."""
    coordinator: KioskDataUpdateCoordinator = hass.data[DOMAIN][entry.entry_id]

    entities = [KioskScreenCamera(coordinator)]

    # If physical camera is detected on the Pi, add room camera entity
    if coordinator.data and coordinator.data.get("has_camera"):
        entities.append(KioskRoomCamera(coordinator))

    async_add_entities(entities)


class KioskScreenCamera(Camera):
    """Camera entity displaying the live kiosk screen display."""

    def __init__(self, coordinator: KioskDataUpdateCoordinator):
        super().__init__()
        self.coordinator = coordinator
        self._attr_unique_id = f"{coordinator.host}_screen_view"
        self._attr_has_entity_name = True
        self._attr_name = "Live Display View"
        self._attr_icon = "mdi:monitor-screenshot"

    @property
    def device_info(self) -> DeviceInfo:
        return DeviceInfo(
            identifiers={(DOMAIN, self.coordinator.host)},
            name=f"RPi Kiosk ({self.coordinator.host})",
            manufacturer="Raspberry Pi",
            model="Cage Wayland Kiosk",
        )

    async def async_camera_image(self, width: int = None, height: int = None) -> bytes:
        """Fetch latest screenshot frame from Kiosk REST API."""
        url = f"{self.coordinator.base_url}/api/screenshot"
        try:
            async with async_timeout.timeout(4):
                async with aiohttp.ClientSession() as session:
                    headers = {}
                    if self.coordinator.pin:
                        headers["X-Kiosk-Pin"] = self.coordinator.pin
                    async with session.get(url, headers=headers) as response:
                        if response.status == 200:
                            return await response.read()
        except Exception as err:
            _LOGGER.debug("Could not fetch kiosk screenshot: %s", err)
        return None


class KioskRoomCamera(Camera):
    """Camera entity displaying live hardware webcam / Pi camera feed."""

    def __init__(self, coordinator: KioskDataUpdateCoordinator):
        super().__init__()
        self.coordinator = coordinator
        self._attr_unique_id = f"{coordinator.host}_room_camera"
        self._attr_has_entity_name = True
        self._attr_name = "Kiosk Room Camera"
        self._attr_icon = "mdi:camera"

    @property
    def device_info(self) -> DeviceInfo:
        return DeviceInfo(
            identifiers={(DOMAIN, self.coordinator.host)},
            name=f"RPi Kiosk ({self.coordinator.host})",
            manufacturer="Raspberry Pi",
            model="Cage Wayland Kiosk",
        )

    async def async_camera_image(self, width: int = None, height: int = None) -> bytes:
        """Fetch latest hardware camera frame from Kiosk REST API."""
        url = f"{self.coordinator.base_url}/api/camera/snapshot"
        try:
            async with async_timeout.timeout(5):
                async with aiohttp.ClientSession() as session:
                    headers = {}
                    if self.coordinator.pin:
                        headers["X-Kiosk-Pin"] = self.coordinator.pin
                    async with session.get(url, headers=headers) as response:
                        if response.status == 200:
                            return await response.read()
        except Exception as err:
            _LOGGER.debug("Could not fetch room camera snapshot: %s", err)
        return None
