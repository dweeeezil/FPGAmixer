// SPDX-License-Identifier: GPL-2.0
/*
 * fpgamixer-link-card: ALSA card for the FPGAmixer PS <-> PL audio link.
 *
 * The link's hardware is the AMD Audio Formatter (DMA, driven by the in-kernel
 * ASoC platform driver xlnx_formatter_pcm) feeding pcm_link in the PL. That
 * driver only becomes a sound card through AMD's xlnx_pl_snd_card, which
 * accepts nothing but AMD's own I2S/HDMI/SDI/SPDIF/DP IP at the other end.
 * Here the other end is the FPGAmixer core, so this module supplies the card:
 * one DAI link, ASoC's dummy DAI as both CPU and codec, the formatter as the
 * platform (the part that actually moves samples).
 *
 * The one thing the card must do is give the formatter its sysclk before a
 * playback stream starts: the formatter writes MM2S Fs multiplier =
 * sysclk / rate and paces the stream at aud_mclk / multiplier. aud_mclk is
 * the PL's mclk, so with "mclk-frequency" = 12288000 at 48 kHz the multiplier
 * is 256: exactly one frame per core frame, and the card runs on mclk time.
 * (Since Phase 9 mclk is locked to gPTP, so the rate is 48 kHz on the
 * network's time; bridging it to any other clock is the job of whatever
 * feeds the card.)
 *
 * Device tree (see system-user.dtsi in meta-fpgamixer):
 *   fpgamixer_link: fpgamixer-link {
 *       compatible = "fpgamixer,pcm-link-card";
 *       audio-formatter = <&...>;          the xlnx,audio-formatter-1.0 node
 *       mclk-frequency = <12288000>;       nominal aud_mclk, Hz
 *       fpgamixer,card-name = "...";       optional, default "FPGAmixerLink"
 *   };
 * One card per link, one node per card. fpgamixer,card-name names the ALSA
 * card (its id, e.g. hw:FPGAmixerLink2) and the DAI link, so every card keeps
 * its name whatever the probe order (Phase 9, P9.5: link #2 is
 * "FPGAmixerLink2"). ALSA card ids are at most 15 characters.
 * The formatter node itself must carry xlnx,tx / xlnx,rx phandles (pointed
 * at this node): its driver dereferences the capture one's node name on
 * every AES->PCM capture hw_params and would oops without it.
 *
 * Docs: docs/phase8_status_2026-09-25.md, docs/phase9_status_2026-09-26.md
 * (sec. 6.8) in the FPGAmixer repo.
 */

#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <sound/pcm_params.h>
#include <sound/soc.h>

#define FORMATTER_COMPONENT "xlnx_formatter_pcm"
#define DEFAULT_CARD_NAME   "FPGAmixerLink"

struct fpgamixer_link {
	struct snd_soc_card card;
	struct snd_soc_dai_link link;
	struct snd_soc_dai_link_component platform;
	u32 mclk_hz;
};

static int fpgamixer_link_hw_params(struct snd_pcm_substream *substream,
				    struct snd_pcm_hw_params *params)
{
	struct snd_soc_pcm_runtime *rtd = snd_soc_substream_to_rtd(substream);
	struct fpgamixer_link *priv = snd_soc_card_get_drvdata(rtd->card);
	struct snd_soc_component *fmt;

	/* The formatter only uses sysclk for MM2S (playback) pacing. */
	if (substream->stream != SNDRV_PCM_STREAM_PLAYBACK)
		return 0;

	fmt = snd_soc_rtdcom_lookup(rtd, FORMATTER_COMPONENT);
	if (!fmt) {
		dev_err(rtd->dev, "audio formatter component not found\n");
		return -ENODEV;
	}
	if (priv->mclk_hz % params_rate(params)) {
		dev_err(rtd->dev, "mclk %u Hz is not a multiple of %u Hz\n",
			priv->mclk_hz, params_rate(params));
		return -EINVAL;
	}
	return snd_soc_component_set_sysclk(fmt, 0, 0, priv->mclk_hz,
					    SND_SOC_CLOCK_OUT);
}

static const struct snd_soc_ops fpgamixer_link_ops = {
	.hw_params = fpgamixer_link_hw_params,
};

static void fpgamixer_link_put_node(void *np)
{
	of_node_put(np);
}

static int fpgamixer_link_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct fpgamixer_link *priv;
	struct device_node *fmt_np;
	const char *name = NULL;
	int ret;

	priv = devm_kzalloc(dev, sizeof(*priv), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;

	if (of_property_read_u32(dev->of_node, "mclk-frequency", &priv->mclk_hz)) {
		dev_err(dev, "missing mclk-frequency\n");
		return -EINVAL;
	}

	fmt_np = of_parse_phandle(dev->of_node, "audio-formatter", 0);
	if (!fmt_np) {
		dev_err(dev, "missing audio-formatter phandle\n");
		return -EINVAL;
	}
	/* Released after the (devm) card is unregistered. */
	ret = devm_add_action_or_reset(dev, fpgamixer_link_put_node, fmt_np);
	if (ret)
		return ret;

	priv->platform.of_node = fmt_np;

	/*
	 * Names. Without fpgamixer,card-name: exactly Phase 8's (card
	 * FPGAmixerLink, DAI link "FPGAmixer link"), which the USB bridge opens.
	 * With it: that string for the card and the DAI link. It must fit the
	 * 15-character ALSA id, or ALSA would shorten it and two cards could
	 * end up with ids that don't say which link they are.
	 */
	of_property_read_string(dev->of_node, "fpgamixer,card-name", &name);
	if (name) {
		if (!*name || strlen(name) > 15) {
			dev_err(dev, "fpgamixer,card-name \"%s\": 1-15 characters\n", name);
			return -EINVAL;
		}
		priv->link.name        = name;
		priv->link.stream_name = devm_kasprintf(dev, GFP_KERNEL, "%s PCM", name);
		if (!priv->link.stream_name)
			return -ENOMEM;
	} else {
		name                   = DEFAULT_CARD_NAME;
		priv->link.name        = "FPGAmixer link";
		priv->link.stream_name = "FPGAmixer link PCM";
	}

	priv->link.cpus          = &snd_soc_dummy_dlc;
	priv->link.num_cpus      = 1;
	priv->link.codecs        = &snd_soc_dummy_dlc;
	priv->link.num_codecs    = 1;
	priv->link.platforms     = &priv->platform;
	priv->link.num_platforms = 1;
	priv->link.ops           = &fpgamixer_link_ops;

	priv->card.name       = name;
	priv->card.owner      = THIS_MODULE;
	priv->card.dev        = dev;
	priv->card.dai_link   = &priv->link;
	priv->card.num_links  = 1;
	snd_soc_card_set_drvdata(&priv->card, priv);

	/* -EPROBE_DEFER until the formatter's component has registered. */
	ret = devm_snd_soc_register_card(dev, &priv->card);
	if (ret)
		return dev_err_probe(dev, ret, "card registration failed\n");

	dev_info(dev, "card %s on %pOF, mclk %u Hz\n",
		 priv->card.name, fmt_np, priv->mclk_hz);
	return 0;
}

static const struct of_device_id fpgamixer_link_of_match[] = {
	{ .compatible = "fpgamixer,pcm-link-card" },
	{ }
};
MODULE_DEVICE_TABLE(of, fpgamixer_link_of_match);

static struct platform_driver fpgamixer_link_driver = {
	.probe  = fpgamixer_link_probe,
	.driver = {
		.name           = "fpgamixer-link-card",
		.of_match_table = fpgamixer_link_of_match,
	},
};
module_platform_driver(fpgamixer_link_driver);

MODULE_DESCRIPTION("FPGAmixer PS<->PL audio link ALSA card (Audio Formatter)");
MODULE_LICENSE("GPL");
