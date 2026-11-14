'use strict';
'require baseclass';
'require ghupdate';

return baseclass.extend({
	title: _('Firmware Updates'),

	load: function() {
		return ghupdate.load();
	},

	render: function(st) {
		return ghupdate.render(st);
	}
});
