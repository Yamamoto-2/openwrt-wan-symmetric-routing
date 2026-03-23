'use strict';
'require view';
'require fs';
'require ui';

return view.extend({
	load: function() {
		return Promise.all([
			fs.exec('/etc/wan-vrf/diagnose.sh').then(function(res) {
				return res.stdout || '';
			}).catch(function() {
				return 'Failed to run diagnostics.\n';
			}),
			fs.exec('/bin/sh', ['-c', 'logread | grep wan-vrf | tail -n 100']).then(function(res) {
				return res.stdout || '';
			}).catch(function() {
				return 'Failed to read logs.\n';
			})
		]);
	},

	render: function(data) {
		var diagOutput = data[0];
		var logOutput = data[1];

		var preStyle = [
			'background:#1a1a2e',
			'color:#e0e0e0',
			'padding:16px',
			'border-radius:6px',
			'font-family:monospace',
			'font-size:13px',
			'line-height:1.6',
			'white-space:pre',
			'overflow:auto',
			'max-height:500px'
		].join(';');

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('WAN Symmetric Routing')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Runtime diagnostics and log viewer.')),

			E('div', { 'class': 'cbi-section' }, [
				E('div', {
					'style': 'display:flex;justify-content:space-between;align-items:center'
				}, [
					E('h3', {}, _('Diagnostics')),
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, 'handleRefresh')
					}, _('Refresh'))
				]),
				E('pre', { 'id': 'diag-output', 'style': preStyle }, diagOutput)
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Recent Logs')),
				E('pre', { 'id': 'log-output', 'style': preStyle },
					logOutput || _('No log entries found.'))
			])
		]);
	},

	handleRefresh: function() {
		return Promise.all([
			fs.exec('/etc/wan-vrf/diagnose.sh').then(function(res) {
				return res.stdout || '';
			}).catch(function() {
				return 'Failed to run diagnostics.\n';
			}),
			fs.exec('/bin/sh', ['-c', 'logread | grep wan-vrf | tail -n 100']).then(function(res) {
				return res.stdout || '';
			}).catch(function() {
				return 'Failed to read logs.\n';
			})
		]).then(function(results) {
			var diagEl = document.getElementById('diag-output');
			var logEl = document.getElementById('log-output');
			if (diagEl) diagEl.textContent = results[0];
			if (logEl) logEl.textContent = results[1] || _('No log entries found.');
		});
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
