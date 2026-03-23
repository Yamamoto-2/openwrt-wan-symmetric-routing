'use strict';
'require form';
'require fs';
'require uci';
'require ui';
'require view';

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('wan_vrf'),
			fs.stat('/tmp/wan-vrf.last_apply').then(function() {
				return true;
			}).catch(function() {
				return false;
			}),
			fs.read('/tmp/wan-vrf.last_apply').then(function(content) {
				var match = content ? content.match(/^last_apply=(.+)$/m) : null;
				return match ? match[1] : null;
			}).catch(function() {
				return null;
			})
		]);
	},

	render: function(data) {
		var isActive = data[1];
		var lastApply = data[2];
		var enabled = uci.get('wan_vrf', 'main', 'enabled') === '1';

		var bannerStyle, bannerText, showButton;
		if (isActive) {
			bannerStyle = 'background:#d4edda;color:#155724;border:1px solid #c3e6cb;';
			bannerText = _('Symmetric routing rules are active.') +
				(lastApply ? ' (' + lastApply + ')' : '');
			showButton = false;
		} else if (enabled) {
			bannerStyle = 'background:#fff3cd;color:#856404;border:1px solid #ffeeba;';
			bannerText = _('Service is enabled but rules are not applied.');
			showButton = true;
		} else {
			bannerStyle = 'background:#f8d7da;color:#721c24;border:1px solid #f5c6cb;';
			bannerText = _('Service is disabled.');
			showButton = true;
		}

		var bannerChildren = [E('span', {}, bannerText)];
		if (showButton) {
			bannerChildren.push(E('button', {
				'class': 'cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, 'handleApply')
			}, enabled ? _('Apply Now') : _('Enable & Apply')));
		}

		var banner = E('div', {
			'style': bannerStyle + 'padding:12px 16px;border-radius:6px;margin-bottom:16px;display:flex;justify-content:space-between;align-items:center;'
		}, bannerChildren);

		var m, s, o;

		m = new form.Map('wan_vrf', _('WAN Symmetric Routing'),
			_('Keep inbound WAN traffic symmetric without changing the main outbound default route. Choose either a firewall zone source or a space-separated interface list source.'));

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

		o = s.option(form.Value, 'public_zone', _('Firewall Zone'));
		o.depends('public_mode', 'zone');
		o.placeholder = 'wan';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			var currentMode = uci.get('wan_vrf', section_id, 'public_mode') || 'zone';
			if (currentMode === 'zone' && (!value || !value.trim()))
				return _('Please enter a firewall zone name.');
			return true;
		};

		o = s.option(form.Value, 'public_ifaces', _('Interface List'));
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

		o = s.option(form.Value, 'lan_network', _('LAN Networks'));
		o.placeholder = 'lan';
		o.rmempty = false;
		o.description = _('Space-separated list of LAN network names. Example: lan lan2');

		o = s.option(form.Value, 'route_table_public', _('Route Table Base'));
		o.datatype = 'uinteger';
		o.placeholder = '100';
		o.rmempty = false;
		o.description = _('Additional active members increment from this base value.');

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

		return m.render().then(function(mapEl) {
			return E('div', {}, [banner, mapEl]);
		});
	},

	handleApply: function() {
		var enabled = uci.get('wan_vrf', 'main', 'enabled') === '1';
		var chain = Promise.resolve();

		if (!enabled) {
			chain = chain.then(function() {
				return uci.set('wan_vrf', 'main', 'enabled', '1');
			}).then(function() {
				return uci.save();
			}).then(function() {
				return uci.apply();
			}).then(function() {
				return fs.exec('/etc/init.d/wan_vrf', ['enable']);
			});
		}

		return chain.then(function() {
			return fs.exec('/etc/init.d/wan_vrf', ['start']);
		}).then(function() {
			location.reload();
		}).catch(function(err) {
			ui.addNotification(null,
				E('p', _('Failed: ') + (err.message || err)));
		});
	}
});
