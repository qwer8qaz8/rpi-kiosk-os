"""Base entity for Raspberry Pi Kiosk."""
from homeassistant.helpers.update_coordinator import CoordinatorEntity
from homeassistant.helpers.entity import DeviceInfo

from .const import DOMAIN
from .coordinator import KioskDataUpdateCoordinator


class KioskBaseEntity(CoordinatorEntity[KioskDataUpdateCoordinator]):
    """Defines a base kiosk entity."""

    def __init__(self, coordinator: KioskDataUpdateCoordinator, key: str, name: str):
        """Initialize the entity."""
        super().__init__(coordinator)
        self._key = key
        self._name = name
        self._attr_unique_id = f"{coordinator.host}_{key}"
        self._attr_has_entity_name = True
        self._attr_name = name

    @property
    def device_info(self) -> DeviceInfo:
        """Return information to link this entity with the correct device."""
        cfg = self.coordinator.data.get("config", {}) if self.coordinator.data else {}
        dev_name = cfg.get("mqtt", {}).get("device_name") or f"RPi Kiosk ({self.coordinator.host})"
        return DeviceInfo(
            identifiers={(DOMAIN, self.coordinator.host)},
            name=dev_name,
            manufacturer="Raspberry Pi",
            model="Cage Wayland Kiosk",
            sw_version=self.coordinator.data.get("version", "1.0.0") if self.coordinator.data else "1.0.0",
            configuration_url=f"http://{self.coordinator.host}:{self.coordinator.port}",
        )
