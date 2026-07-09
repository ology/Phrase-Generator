# Phrase-Generator

This is a simple real-time MIDI phrase generator app that I use and experiment with. YMMV

1. Install `fluidsynth` - https://www.fluidsynth.org/
2. Install Perl, including the `cpanm` utility.
   1. Windows - https://strawberryperl.com/
   2. Everyone else - Use your package manager or get it from https://www.perl.org/
3. Install the Perl dependencies:
```shell
cpanm --verbose --installdeps .
```
4. Run the app:
```shell
morbo phrase-generator.pl --verbose --listen http://127.0.0.1:3333
```
5. Browse to http://127.0.0.1:3333/
6. Voila!
