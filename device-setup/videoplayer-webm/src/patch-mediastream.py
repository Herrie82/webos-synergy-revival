#!/usr/bin/env python3
# patch-mediastream.py <file> - in-place mislabel patch for a mediastream framework JS file.
#
# The stock videoplayer's <video> element is driven by the mediastream framework's StreamingPlayEngine,
# which does `this.player.src = url` + `this.player.load()`. WebKit's MediaPlayerPrivatePalm::supportsType()
# has no video/webm entry, so a bare .webm src never loads. But the media server (which actually decodes)
# is a generic decodebin that typefinds the real bytes and, with the autoplug shim, decodes VP8/VP9 fine.
# So for the containers WebKit rejects (webm/mkv) we hand it a <source> mime it DOES accept (video/ogg);
# WebKit then instantiates its engine and the media server plays the real WebM. Other formats untouched.
#
# Idempotent: exits 0 without changes if the file is already patched. Handles both the minified
# (`this.player.src=url;`) and pretty (`\t\tthis.player.src = url;`) forms.
import sys

MIN_OLD = "this.player.src=url;"
MIN_NEW = ('if(/\\.(webm|mkv)(\\?|#|$)/i.test(url)){this.player.removeAttribute("src");'
           'while(this.player.firstChild){this.player.removeChild(this.player.firstChild);}'
           'var _msrc=this.player.ownerDocument.createElement("source");'
           '_msrc.setAttribute("src",url);_msrc.setAttribute("type","video/ogg");'
           'this.player.appendChild(_msrc);this.player.load();}else{this.player.src=url;}')

PRETTY_OLD = "\t\tthis.player.src = url;"
PRETTY_NEW = ("\t\t// WebKit's supportsType() rejects video/webm; hand it a <source> mime it accepts\n"
              "\t\t// (video/ogg) so its engine loads, then the media server typefinds and decodes the\n"
              "\t\t// real WebM. Only webm/mkv are rerouted; every other format keeps its direct src.\n"
              "\t\tif (/\\.(webm|mkv)(\\?|#|$)/i.test(url)) {\n"
              "\t\t\tthis.player.removeAttribute('src');\n"
              "\t\t\twhile (this.player.firstChild) { this.player.removeChild(this.player.firstChild); }\n"
              "\t\t\tvar _msrc = this.player.ownerDocument.createElement('source');\n"
              "\t\t\t_msrc.setAttribute('src', url);\n"
              "\t\t\t_msrc.setAttribute('type', 'video/ogg');\n"
              "\t\t\tthis.player.appendChild(_msrc);\n"
              "\t\t\tthis.player.load(); // dynamically-appended <source> needs an explicit load() (setting .src auto-loads; appendChild does not)\n"
              "\t\t} else {\n"
              "\t\t\tthis.player.src = url;\n"
              "\t\t}")


def main():
    path = sys.argv[1]
    s = open(path, encoding="latin-1").read()
    if "video/ogg" in s and "_msrc" in s:
        print("  already patched: %s" % path)
        return 0
    # Prefer the minified token; fall back to the pretty/tab-indented one.
    if s.count(MIN_OLD) == 1:
        s = s.replace(MIN_OLD, MIN_NEW)
    elif s.count(PRETTY_OLD) == 1:
        s = s.replace(PRETTY_OLD, PRETTY_NEW)
    else:
        sys.stderr.write("  ERROR: could not find a unique `this.player.src = url` in %s "
                         "(min=%d pretty=%d)\n" % (path, s.count(MIN_OLD), s.count(PRETTY_OLD)))
        return 1
    open(path, "w", encoding="latin-1").write(s)
    print("  patched: %s" % path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
