'use strict';
'require baseclass';
'require fs';
'require ui';

// Shared by the Status > Overview box and the System > Firmware Updates page.

var CMD = '/usr/sbin/ghupdate';
var STATUS = '/tmp/ghupdate/status.json';

function esc(s) {
	return String(s == null ? '' : s).replace(/[&<>"']/g, function(c) {
		return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
	});
}

function when(epoch) {
	if (!epoch)
		return '?';
	return esc(new Date(epoch * 1000).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }));
}

function build(b) {
	if (!b || !b.openwrt || b.openwrt === 'unknown')
		return esc(_('unknown build'));
	return esc('OpenWrt %s (build %d)'.format(b.openwrt, b.serial));
}

return baseclass.extend({
	load: function() {
		return L.resolveDefault(fs.read(STATUS), null).then(function(raw) {
			try { return raw ? JSON.parse(raw) : null; }
			catch (e) { return null; }
		});
	},

	button: function(label, handler, arg, primary) {
		return E('button', {
			'class': primary ? 'btn cbi-button-action important' : 'btn',
			'click': ui.createHandlerFn(this, handler, arg)
		}, [ label ]);
	},

	handleCheck: function(arg, ev) {
		return fs.exec(CMD, [ 'check' ]).then(function(res) {
			if (res.code !== 0)
				ui.addNotification(null, E('p', esc(_('Update check failed: %s').format((res.stderr || '').trim()))), 'warning');
			window.location.reload();
		});
	},

	handleInstall: function(st, ev) {
		ui.showModal(_('Install firmware update?'), [
			E('p', _('Install %s? Settings are kept. Wi-Fi is down for about three minutes while the access point flashes and reboots.').format(build(st.latest))),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]), ' ',
				E('button', { 'class': 'btn cbi-button-action important', 'click': ui.createHandlerFn(this, 'doInstall') }, [ _('Install') ])
			])
		]);
	},

	doInstall: function() {
		ui.showModal(_('Preparing update…'), [
			E('p', { 'class': 'spinning' }, _('Downloading the image and checking its signature and checksum.'))
		]);
		return fs.exec(CMD, [ 'prepare' ]).then(function(res) {
			if (res.code !== 0) {
				ui.hideModal();
				ui.addNotification(null, [
					E('p', _('The update was not installed.')),
					E('pre', {}, [ (res.stderr || res.stdout || '').trim() ])
				], 'danger');
				return;
			}
			ui.showModal(_('Flashing…'), [
				E('p', { 'class': 'spinning' }, _('The system is flashing now.<br /> DO NOT POWER OFF THE DEVICE!<br /> This page reconnects by itself when the access point is back, usually within three minutes.'))
			]);
			fs.exec(CMD, [ 'apply' ]);
			ui.awaitReconnect(window.location.host);
		});
	},

	render: function(st) {
		var rows = [], btns = [], a;

		if (!st || !st.installed) {
			rows.push(E('p', _('No update information yet. The access point checks for new builds every hour.')));
		}
		else if (st.update_available) {
			a = st.auto || {};
			rows.push(E('p', [ E('strong', _('Firmware update available: %s').format(build(st.latest))) ]));
			rows.push(E('p', _('Installed: %s. The update was released %s.').format(build(st.installed), when(st.latest.published))));
			rows.push(E('p', a.blocked
				? _('Not installing automatically: %s.').format(esc(a.blocked))
				: _('Installs automatically around %s if you do nothing.').format(when(a.next))));
			btns.push(this.button(_('Install now'), 'handleInstall', st, true));
			if (/^https:\/\/github\.com\//.test(st.latest.url || ''))
				btns.push(E('a', { 'class': 'btn', 'href': st.latest.url, 'target': '_blank', 'rel': 'noreferrer' }, [ _('Release notes') ]));
		}
		else {
			rows.push(E('p', _('Up to date: %s.').format(build(st.installed))));
		}

		if (st && st.state === 'error')
			rows.push(E('p', { 'class': 'alert-message warning' }, _('Last check failed: %s').format(esc(st.message))));
		if (st && st.last_check)
			rows.push(E('p', { 'style': 'opacity:.7' }, _('Last checked %s against %s.').format(when(st.last_check), esc(st.repo))));
		if (!st || !st.update_available)
			btns.push(this.button(_('Check now'), 'handleCheck'));

		rows.push(E('div', {}, btns.reduce(function(acc, b) { return acc.concat(acc.length ? [ ' ', b ] : [ b ]); }, [])));
		return E('div', {}, rows);
	}
});
