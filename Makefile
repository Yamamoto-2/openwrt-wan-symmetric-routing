include $(TOPDIR)/rules.mk

PKG_NAME:=wan-symmetric-routing
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Codex
PKG_BUILD_PARALLEL:=1
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/wan-symmetric-routing
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Routing and Redirection
  TITLE:=Dual-WAN symmetric return-path routing helper
  DEPENDS:=+ip-full +iptables +jsonfilter +ubus +uci
endef

define Package/wan-symmetric-routing/description
 A shell-first helper package for OpenWrt and iStoreOS that keeps inbound
 public-WAN connections symmetric while leaving the normal default route on
 the fast WAN.
endef

define Package/luci-app-wan-symmetric-routing
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for WAN Symmetric Routing
  DEPENDS:=+wan-symmetric-routing +luci-base
endef

define Package/luci-app-wan-symmetric-routing/description
 LuCI frontend for configuring WAN Symmetric Routing.
endef

define Build/Compile
endef

define Package/wan-symmetric-routing/conffiles
/etc/config/wan_vrf
endef

define Package/wan-symmetric-routing/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/wan_vrf $(1)/etc/config/wan_vrf

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/wan_vrf $(1)/etc/init.d/wan_vrf

	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./root/etc/hotplug.d/iface/95-wan-vrf $(1)/etc/hotplug.d/iface/95-wan-vrf

	$(INSTALL_DIR) $(1)/etc/hotplug.d/firewall
	$(INSTALL_BIN) ./root/etc/hotplug.d/firewall/95-wan-vrf $(1)/etc/hotplug.d/firewall/95-wan-vrf

	$(INSTALL_DIR) $(1)/etc/wan-vrf
	$(INSTALL_BIN) ./root/etc/wan-vrf/core.sh $(1)/etc/wan-vrf/core.sh
	$(INSTALL_BIN) ./root/etc/wan-vrf/apply.sh $(1)/etc/wan-vrf/apply.sh
	$(INSTALL_BIN) ./root/etc/wan-vrf/diagnose.sh $(1)/etc/wan-vrf/diagnose.sh
endef

define Package/luci-app-wan-symmetric-routing/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/wan-symmetric-routing
	$(INSTALL_DATA) ./luci/htdocs/luci-static/resources/view/wan-symmetric-routing/settings.js $(1)/www/luci-static/resources/view/wan-symmetric-routing/settings.js

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./luci/root/usr/share/luci/menu.d/luci-app-wan-symmetric-routing.json $(1)/usr/share/luci/menu.d/luci-app-wan-symmetric-routing.json

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./luci/root/usr/share/rpcd/acl.d/luci-app-wan-symmetric-routing.json $(1)/usr/share/rpcd/acl.d/luci-app-wan-symmetric-routing.json
endef

$(eval $(call BuildPackage,wan-symmetric-routing))
$(eval $(call BuildPackage,luci-app-wan-symmetric-routing))