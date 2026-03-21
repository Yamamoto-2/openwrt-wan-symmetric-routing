'use strict';
'require form';
'require uci';
'require view';

return view.extend({
	load: function() {
		return uci.load('wan_vrf');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('wan_vrf', _('WAN Symmetric Routing'),
			_('Keep inbound WAN traffic symmetric without changing the main outbound default route. Choose public and LAN sources either from firewall zones or from space-separated logical interface lists.'));

		s = m.section(form.NamedSection, 'main', 'settings', _('Settings'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;
		o.default = o.disabled;

		o = s.option(form.ListValue, 'mode', _('Routing Mode'));
		o.value('fwmark', _('fwmark'));
		o.rmempty = false;
		o.default = 'fwmark';
		o.readonly = true;
		o.description = _('Only fwmark mode is implemented right now.');

		o = s.option(form.ListValue, 'public_mode', _('Public Member Source'));
		o.value('zone', _('Firewall Zone'));
		o.value('iface_list', _('Interface List'));
		o.rmempty = false;
		o.default = 'zone';

		o = s.option(form.Value, 'public_zone', _('Public Firewall Zone'));
		o.depends('public_mode', 'zone');
		o.placeholder = 'wan';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			var currentMode = uci.get('wan_vrf', section_id, 'public_mode') || 'zone';
			if (currentMode === 'zone' && (!value || !value.trim()))
				return _('Please enter a firewall zone name.');
			return true;
		};

		o = s.option(form.Value, 'public_ifaces', _('Public Interface List'));
		o.depends('public_mode', 'iface_list');
		o.placeholder = 'wan wan2';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			var currentMode = uci.get('wan_vrf', section_id, 'public_mode') || 'zone';
			if (currentMode === 'iface_list' && (!value || !value.trim()))
				return _('Please enter one or more logical interface names separated by spaces.');
			return true;
		};
		o.description = _('Example: wan wan2');

		o = s.option(form.ListValue, 'lan_mode', _('LAN Source'));
		o.value('zone', _('Firewall Zone'));
		o.value('iface_list', _('Interface List'));
		o.rmempty = false;
		o.default = 'zone';

		o = s.option(form.Value, 'lan_zone', _('LAN Firewall Zone'));
		o.depends('lan_mode', 'zone');
		o.placeholder = 'lan';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			var currentMode = uci.get('wan_vrf', section_id, 'lan_mode') || 'zone';
			if (currentMode === 'zone' && (!value || !value.trim()))
				return _('Please enter a LAN firewall zone name.');
			return true;
		};

		o = s.option(form.Value, 'lan_ifaces', _('LAN Interface List'));
		o.depends('lan_mode', 'iface_list');
		o.placeholder = 'lan iot guest';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			var currentMode = uci.get('wan_vrf', section_id, 'lan_mode') || 'zone';
			if (currentMode === 'iface_list' && (!value || !value.trim()))
				return _('Please enter one or more LAN interface names separated by spaces.');
			return true;
		};
		o.description = _('Example: lan iot guest. Use an interface list when replies may leave through multiple internal zones.');

		o = s.option(form.Value, 'route_table_public', _('Route Table Base'));
		o.datatype = 'uinteger';
		o.placeholder = '100';
		o.rmempty = false;
		o.description = _('Additional active public members increment from this base value.');

		o = s.option(form.Value, 'fwmark_public', _('FWMark Base'));
		o.placeholder = '0x100';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			if (!value || !value.match(/^0x[0-9a-fA-F]+$/))
				return _('Use a hexadecimal mark such as 0x100.');
			return true;
		};

		o = s.option(form.Value, 'rule_priority', _('Rule Priority Base'));
		o.datatype = 'uinteger';
		o.placeholder = '10000';
		o.rmempty = false;

		o = s.option(form.Flag, 'auto_apply', _('Auto Apply'));
		o.rmempty = false;
		o.default = o.enabled;
		o.description = _('Reapply rules on interface and firewall hotplug events.');

		o = s.option(form.Flag, 'debug', _('Debug Logging'));
		o.rmempty = false;
		o.default = o.disabled;
		o.description = _('Write extra diagnostics to logread when troubleshooting.');

		return m.render();
	}
});