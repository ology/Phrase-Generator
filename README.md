# MIDI Phrase Generator

This is a simple real-time MIDI phrase generator app that I use and experiment with. YMMV

1. Install `fluidsynth` - https://www.fluidsynth.org/

2. Install Perl, including the `cpanm` utility.
   1. Windows
      1. https://strawberryperl.com/
   2. Everyone else
      1. Use your package manager
      2. Or get it from https://www.perl.org/
      3. Or use `plenv`
      4. Or use `perlbrew`

3. Clone the repo and change to that directory:
```shell
git clone https://github.com/ology/Phrase-Generator.git
cd Phrase-Generator/
```

4. Install the Perl dependencies:
```shell
cpanm --verbose --installdeps .
```

5. Run the app:
```shell
morbo phrase-generator.pl --verbose --listen http://127.0.0.1:3333
```

6. Browse to http://127.0.0.1:3333/

7. Voila!
