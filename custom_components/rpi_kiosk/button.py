"""Button platform for Raspberry Pi Kiosk."""
from homeassistant.components.button import ButtonEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .const import DOMAIN
from .entity import KioskBaseEntity
from .coordinator import KioskDataUpdateCoordinator


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    """Set up the Kiosk button entities."""
    coordinator: KioskDataUpdateCoordinator = hass.data[DOMAIN][entry.entry_id]

    async_add_entities([
        KioskReloadButton(coordinator),
        KioskRebootButton(coordinator),
        KioskUpdateButton(coordinator),
    ])


class KioskReloadButton(KioskBaseEntity, ButtonEntity):
    """Button to reload the kiosk Chromium display."""

    def __init__(self, coordinator: KioskDataUpdateCoordinator):
        super().__init__(coordinator, key="reload", name="Reload Display")
        self._attr_icon = "mdi:refresh"

    async def async_press(self) -> None:
        """Trigger display reload."""
        await self.coordinator.async_send_command("reload")
        await self.coordinator.async_request_refresh()


class KioskRebootButton(KioskBaseEntity, ButtonEntity):
    """Button to reboot the Raspberry Pi."""

    def __init__(self, coordinator: KioskDataUpdateCoordinator):
        super().__init__(coordinator, key="reboot", name="Reboot Kiosk")
        self._attr_icon = "mdi:restart"

    async def async_press(self) -> None:
        """Trigger Pi reboot."""
        await self.coordinator.async_send_command("reboot")


class KioskUpdateButton(KioskBaseEntity, ButtonEntity):
    """Button to update the kiosk software from GitHub."""

    def __init__(self, coordinator: KioskDataUpdateCoordinator):
        super().__init__(coordinator, key="update", name="Update Software")
        self._attr_icon = "mdi:cloud-download"

    async def async_press(self) -> None:
        """Trigger system update from GitHub."""
        await self.coordinator.async_send_command("update")
        await self.coordinator.async_request_refresh()
