"""Switch platform for Raspberry Pi Kiosk."""
from homeassistant.components.switch import SwitchEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .const import DOMAIN
from .entity import KioskBaseEntity
from .coordinator import KioskDataUpdateCoordinator


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    """Set up the Kiosk switch entities."""
    coordinator: KioskDataUpdateCoordinator = hass.data[DOMAIN][entry.entry_id]

    async_add_entities([
        KioskScreenSwitch(coordinator),
        KioskLockdownSwitch(coordinator),
    ])


class KioskScreenSwitch(KioskBaseEntity, SwitchEntity):
    """Switch for physical screen display power."""

    def __init__(self, coordinator: KioskDataUpdateCoordinator):
        super().__init__(coordinator, key="screen_power", name="Screen Power")
        self._attr_icon = "mdi:monitor"

    @property
    def is_on(self) -> bool:
        """Return true if screen is on."""
        if not self.coordinator.data:
            return True
        return self.coordinator.data.get("screen_status", "ON") == "ON"

    async def async_turn_on(self, **kwargs) -> None:
        """Turn the screen on."""
        await self.coordinator.async_send_command("screen", {"action": "on"})
        await self.coordinator.async_request_refresh()

    async def async_turn_off(self, **kwargs) -> None:
        """Turn the screen off."""
        await self.coordinator.async_send_command("screen", {"action": "off"})
        await self.coordinator.async_request_refresh()


class KioskLockdownSwitch(KioskBaseEntity, SwitchEntity):
    """Switch for enterprise URL & shortcut lockdown."""

    def __init__(self, coordinator: KioskDataUpdateCoordinator):
        super().__init__(coordinator, key="lockdown", name="Lockdown Mode")
        self._attr_icon = "mdi:shield-lock"

    @property
    def is_on(self) -> bool:
        """Return true if lockdown is on."""
        if not self.coordinator.data:
            return False
        cfg = self.coordinator.data.get("config", {})
        return bool(cfg.get("lockdown", True))

    async def async_turn_on(self, **kwargs) -> None:
        """Turn lockdown on."""
        await self.coordinator.async_send_command("lockdown", {"action": "on"})
        await self.coordinator.async_request_refresh()

    async def async_turn_off(self, **kwargs) -> None:
        """Turn lockdown off."""
        await self.coordinator.async_send_command("lockdown", {"action": "off"})
        await self.coordinator.async_request_refresh()
