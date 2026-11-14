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
		}).catch(function() {}).then(function() {
			window.location.reload();
		});
	},

	// Poll status.json until the background 'prepare' finishes. Resolves on 'ready', rejects on
	// 'error', 'up-to-date' or timeout. Each poll is a quick file read, so no RPC call runs long.
	waitPrepared: function(progressEl, deadline) {
		var self = this;
		return new Promise(function(resolve, reject) {
			(function poll() {
				self.load().then(function(st) {
					var s = st && st.state;
					if (st && st.message)
						progressEl.textContent = st.message + '…';
					if (s === 'ready')
						return resolve(st);
					if (s === 'error')
						return reject(new Error(st.message || _('unknown error')));
					if (s === 'up-to-date')
						return reject(new Error(_('There is no newer build to install.')));
					if (Date.now() > deadline)
						return reject(new Error(_('Timed out after 5 minutes waiting for the download.')));
					window.setTimeout(poll, 2000);
				}).catch(function() {
					window.setTimeout(poll, 2000);
				});
			})();
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
		var self = this,
		    progress = E('span', {}, [ _('Starting…') ]);

		ui.showModal(_('Preparing update…'), [
			E('p', { 'class': 'spinning' }, [ progress ]),
			E('p', { 'style': 'opacity:.7' }, _('Downloading the image and checking its signature and checksum. This usually takes under a minute; nothing changes on the device until it is verified.'))
		]);

		return fs.exec(CMD, [ 'start' ]).then(function(res) {
			if (res.code !== 0)
				throw new Error((res.stderr || res.stdout || '').trim() || ('exit code ' + res.code));
			return self.waitPrepared(progress, Date.now() + 5 * 60 * 1000);
		}).then(function() {
			ui.showModal(_('Flashing…'), [
				E('p', { 'class': 'spinning' }, _('The system is flashing now.<br /> DO NOT POWER OFF THE DEVICE!<br /> This page reconnects by itself when the access point is back, usually within three minutes.'))
			]);
			fs.exec(CMD, [ 'apply' ]).catch(function() {});   // the connection drops as it flashes
			ui.awaitReconnect(window.location.host);
		}).catch(function(err) {
			ui.showModal(_('Update not installed'), [
				E('p', _('The update was not installed. The device is unchanged.')),
				E('pre', {}, [ String((err && err.message) || err) ]),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': function() { ui.hideModal(); window.location.reload(); } }, [ _('Close') ])
				])
			]);
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
