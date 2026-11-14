'use strict';
'require view';
'require form';
'require ghupdate';

return view.extend({
	load: function() {
		return ghupdate.load();
	},

	render: function(st) {
		var m, s, o, h;

		m = new form.Map('ghupdate', _('Firmware Updates'),
			_('Signed OpenWrt builds for this access point, published as GitHub releases. Each build keeps the preinit/failsafe address off the LAN (192.168.255.1).'));

		s = m.section(form.NamedSection, 'main', 'settings', _('Automatic installation'));

		o = s.option(form.Flag, 'auto', _('Install updates automatically'),
			_('When off, updates are only shown here and on the Overview page, and install when you click Install now.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'soak_days', _('Minimum release age (days)'),
			_('Wait this long after a build is published before installing it automatically. That leaves time to pull a bad build.'));
		o.datatype = 'range(0,60)';
		o.placeholder = '3';
		o.depends('auto', '1');

		o = s.option(form.ListValue, 'hour', _('Install hour'),
			_('Automatic installs only run during this hour (local time).'));
		for (h = 0; h < 24; h++)
			o.value(String(h), '%02d:00 – %02d:59'.format(h, h));
		o.default = '4';
		o.depends('auto', '1');

		o = s.option(form.Flag, 'auto_major', _('Also auto-install new release series'),
			_('For example 25.12 to 26.x. When off, a new series waits for you to click Install now.'));
		o.default = '0';
		o.depends('auto', '1');

		o = s.option(form.Value, 'repo', _('GitHub repository'));
		o.placeholder = 'oliviacpu/openwrt-home-aps';
		o.datatype = 'string';

		return m.render().then(function(mapEl) {
			return E([], [
				E('div', { 'class': 'cbi-section' }, [
					E('h3', _('Status')),
					ghupdate.render(st)
				]),
				mapEl
			]);
		});
	}
});
