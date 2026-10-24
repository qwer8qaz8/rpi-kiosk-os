"""Number platform for Raspberry Pi Kiosk."""
from homeassistant.components.number import NumberEntity, NumberMode
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .const import DOMAIN
from .entity import KioskBaseEntity
from .coordinator import KioskDataUpdateCoordinator


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    """Set up the Kiosk number entities."""
    coordinator: KioskDataUpdateCoordinator = hass.data[DOMAIN][entry.entry_id]

    async_add_entities([
        KioskBrightnessNumber(coordinator),
    ])


class KioskBrightnessNumber(KioskBaseEntity, NumberEntity):
    """Number slider for screen brightness (1-100%)."""

    def __init__(self, coordinator: KioskDataUpdateCoordinator):
        super().__init__(coordinator, key="brightness", name="Brightness")
        self._attr_native_min_value = 1
        self._attr_native_max_value = 100
        self._attr_native_step = 1
        self._attr_mode = NumberMode.SLIDER
        self._attr_icon = "mdi:brightness-6"
        self._attr_native_unit_of_measurement = "%"

    @property
    def native_value(self) -> float:
        """Return the current brightness."""
        if not self.coordinator.data:
            return 100
        return float(self.coordinator.data.get("brightness", 100))

    async def async_set_native_value(self, value: float) -> None:
        """Set screen brightness."""
        await self.coordinator.async_send_command("brightness", {"brightness": int(value)})
        await self.coordinator.async_request_refresh()
