"""Sensor platform for Raspberry Pi Kiosk."""
from homeassistant.components.sensor import (
    SensorEntity,
    SensorDeviceClass,
    SensorStateClass,
)
from homeassistant.const import UnitOfTemperature
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .const import DOMAIN
from .entity import KioskBaseEntity
from .coordinator import KioskDataUpdateCoordinator


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    """Set up the Kiosk sensor entities."""
    coordinator: KioskDataUpdateCoordinator = hass.data[DOMAIN][entry.entry_id]

    async_add_entities([
        KioskUrlSensor(coordinator),
        KioskTemperatureSensor(coordinator),
        KioskUptimeSensor(coordinator),
        KioskIpSensor(coordinator),
    ])


class KioskUrlSensor(KioskBaseEntity, SensorEntity):
    """Sensor reporting the active dashboard URL."""

    def __init__(self, coordinator: KioskDataUpdateCoordinator):
        super().__init__(coordinator, key="url", name="Active Dashboard URL")
        self._attr_icon = "mdi:web"

    @property
    def native_value(self) -> str:
        if not self.coordinator.data:
            return ""
        return self.coordinator.data.get("config", {}).get("dashboard_url", "")


class KioskTemperatureSensor(KioskBaseEntity, SensorEntity):
    """Sensor reporting the Pi CPU temperature."""

    def __init__(self, coordinator: KioskDataUpdateCoordinator):
        super().__init__(coordinator, key="temperature", name="CPU Temperature")
        self._attr_device_class = SensorDeviceClass.TEMPERATURE
        self._attr_state_class = SensorStateClass.MEASUREMENT
        self._attr_native_unit_of_measurement = UnitOfTemperature.CELSIUS
        self._attr_icon = "mdi:thermometer"

    @property
    def native_value(self) -> float:
        if not self.coordinator.data:
            return None
        temp = self.coordinator.data.get("cpu_temp")
        try:
            return float(temp)
        except (ValueError, TypeError):
            return None


class KioskUptimeSensor(KioskBaseEntity, SensorEntity):
    """Sensor reporting system uptime."""

    def __init__(self, coordinator: KioskDataUpdateCoordinator):
        super().__init__(coordinator, key="uptime", name="Uptime")
        self._attr_icon = "mdi:clock-outline"

    @property
    def native_value(self) -> str:
        if not self.coordinator.data:
            return ""
        return str(self.coordinator.data.get("uptime", ""))


class KioskIpSensor(KioskBaseEntity, SensorEntity):
    """Sensor reporting kiosk local IP address."""

    def __init__(self, coordinator: KioskDataUpdateCoordinator):
        super().__init__(coordinator, key="ip", name="IP Address")
        self._attr_icon = "mdi:ip-network"

    @property
    def native_value(self) -> str:
        if not self.coordinator.data:
            return ""
        return str(self.coordinator.data.get("ip", self.coordinator.host))
