# Research references

This repository implements its own Swift file codecs and PTP/IP session. It does not vendor the following projects or distribute their recipe collections. Their work was consulted when investigating file layouts and protocol behavior:

- [ssssota/nikon-flexible-color-picture-control](https://github.com/ssssota/nikon-flexible-color-picture-control), MIT. Flexible Color fields, curve layout and NP3 serialization research.
- [horshack-dpreview/NikonPictureControlsDev](https://github.com/horshack-dpreview/NikonPictureControlsDev). Picture Control curve and lookup-table research.
- [tvgenious89/nikon-pc](https://github.com/tvgenious89/nikon-pc). Traditional Picture Control editor and file-format comparison. Its curve implementation is not copied here.
- [fistulareffigy/Nikon-NP3-NCP-TOOL](https://github.com/fistulareffigy/Nikon-NP3-NCP-TOOL), MIT. Template-based repair research; its repair implementation is not used here.
- [dukus/digiCamControl](https://github.com/dukus/digiCamControl) and [discordj/QNikonCamera](https://github.com/discordj/QNikonCamera). Nikon operation identifiers and historical data handling references; source implementations are not bundled.
- [Nikon Z30 online manual](https://onlinemanual.nikonimglib.com/z30/en/09-03-12.html) and [NX Studio Flexible Color documentation](https://nikonimglib.com/nxstdo/onlinehelp/en/the_picture_controls_flexible_color_23.html).

Nikon and its product names belong to their respective owners. The MIT license in this repository applies to this project's code and generated test fixtures, not to external software, Nikon documentation, or third-party photographic presets.
