#!/usr/bin/env perl

use Mojolicious::Lite -signatures;

use feature qw(say try signatures);
no warnings qw(experimental::try experimental::signatures);

use Data::Dumper::Compact qw(ddc);
use Getopt::Long qw(GetOptionsFromArray);
use MIDI::RtMidi::FFI::Device ();
use MIDI::Util qw(dura_size midi_dump scale_names);
use Music::Scales qw(get_scale_MIDI);
use Music::VoicePhrase ();
use IPC::Open2 qw(open2);
use Storable qw(retrieve store);
use Scalar::Util qw(refaddr);

use constant {
    DIVISIONS       => 12, # divisions of a quarter-note
    CLOCKS_PER_BEAT => 24, # PPQN
    SAVED           => 'saved-units.dat',
};

my %opt = (
    port    => 'fluidsynth',
    bpm     => 60,
    base    => 'C',
    verbose => 1,
);
GetOptionsFromArray(\@ARGV, \%opt,
    'port=s',
    'bpm=i',
    'base=s',
    'verbose=s',
);

store {}, SAVED unless -e SAVED;
my $saved_parts = retrieve(SAVED);

my %edit; # edit a part

# redefine what happens on ^C, same as the original script
$SIG{INT} = sub {
    say "\nStop" if $opt{verbose};
    stop_sequencer();
    exit;
};

my $clock_interval; # time / bpm / ppqn, recomputed whenever bpm changes
my $tick_div = CLOCKS_PER_BEAT / DIVISIONS; # clocks per 16th-note

recompute_timing();

my $ticks      = 0;  # clock ticks
my $beat_count = 0;  # how many beats?
my @parts;           # Music::VoicePhrase objects
my $midi_out;        # RtMidiOut instance
my $timer_id;        # Mojo::IOLoop->recurring id while running
my ($fluid_out, $fluid_in);      # for open2()
my %voice_owner; # $voice_owner{$channel}{$pitch} = refaddr of currently sounding note
my %muted_parts; # don't play these

my %choices = (
    patch       => midi_dump('patch2number'),
    number      => midi_dump('number2patch'),
    scale_names => scale_names(),
    pool        => {
        'wn'           => [qw(wn)],
        'hn'           => [qw(hn)],
        'qn'           => [qw(qn)],
        'en'           => [qw(en)],
        'sn'           => [qw(sn)],
        'wn hn'        => [qw(wn hn)],
        'hn qn'        => [qw(hn qn)],
        'qn en'        => [qw(qn en)],
        'en sn'        => [qw(en sn)],
        'wn hn qn'     => [qw(wn hn qn)],
        'hn qn en'     => [qw(hn qn en)],
        'qn en sn'     => [qw(qn en sn)],
        'wn dhn hn qn' => [qw(wn dhn hn qn)],
        'hn dqn qn en' => [qw(hn dqn qn en)],
        'qn den en sn' => [qw(qn den en sn)],
        'thn'          => [qw(thn)],
        'tqn'          => [qw(tqn)],
        'ten'          => [qw(ten)],
        'tsn'          => [qw(tsn)],
        'tqn hn'       => [qw(tqn hn)],
        'ten qn'       => [qw(ten qn)],
        'tsn en'       => [qw(tsn en)],
    },
    pitches => {
        '1 octave'  => sub ($base, $octave, $scale) {
            get_scale_MIDI($base, $octave, $scale);
        },
        '2 octaves' => sub ($base, $octave, $scale) {
            get_scale_MIDI($base, $octave, $scale),
            get_scale_MIDI($base, $octave + 1, $scale);
        },
        '3 octaves' => sub ($base, $octave, $scale) {
            get_scale_MIDI($base, $octave, $scale),
            get_scale_MIDI($base, $octave + 1, $scale),
            get_scale_MIDI($base, $octave + 2, $scale);
        },
    },
    intervals => {
        '-3..3' => [(-3 .. 3)],
        '-4..4' => [(-4 .. 4)],
        '-5..5' => [(-5 .. 5)],
        '-7..7' => [(-7 .. 7)],
        '-3..-1,1..3' => [(-3 .. -1), (1 .. 3)],
        '-4..-1,1..4' => [(-4 .. -1), (1 .. 4)],
        '-5..-1,1..5' => [(-5 .. -1), (1 .. 5)],
        '-7..-1,1..7' => [(-7 .. -1), (1 .. 7)],
    },
    keys_order => [qw(
        C
        C♯
        D♭
        D
        D♯
        E♭
        E
        F
        F♯
        G♭
        G
        G♯
        A♭
        A
        A♯
        B♭
        B
    )],
    keys => {
        'C'  => 'C',
        'C♯' => 'C#',
        'D♭' => 'Db',
        'D'  => 'D',
        'D♯' => 'D#',
        'E♭' => 'Eb',
        'E'  => 'E',
        'F'  => 'F',
        'F♯' => 'F#',
        'G♭' => 'Gb',
        'G'  => 'G',
        'G♯' => 'G#',
        'A♭' => 'Ab',
        'A'  => 'A',
        'A♯' => 'A#',
        'B♭' => 'Bb',
        'B'  => 'B',
    },
    parameters => [qw(
        channel
        name
        patch
        gate
        volume
        motif_num
        scale
        octave
        size
        pool
        weights
        groups
        pitches
        pitches_name
        intervals
        intervals_name
    )],
);


#################################################
#
#  Rt-MIDI
#
#################################################

sub recompute_timing {
    $clock_interval = 60 / $opt{bpm} / CLOCKS_PER_BEAT;
}

sub open_midi {
    return if $midi_out;
    $midi_out = RtMidiOut->new;
    try { $midi_out->open_virtual_port('RtMidiOut') } # needed for mac
    catch ($e) { warn 'Not a Mac' if $opt{verbose} }
    sleep(1); # band-aid the race condition
    try { $midi_out->open_port_by_name(qr/\Q$opt{port}/i) }
    catch ($e) { die "Can't open MIDI port $opt{port}\n" }
    say "Sending MIDI to $opt{port} at $opt{bpm} BPM" if $opt{verbose};
    $midi_out->start;
}

sub send_program_changes {
    for my $part (@parts) {
        $midi_out->program_change($part->{channel}, $part->{patch})
            if defined $part->{patch};
        $midi_out->control_change($part->{channel}, 7, $part->{volume})
            if defined $part->{volume};
    }
}

sub panic_all {
    return unless $midi_out;
    try {
        $midi_out->stop;
        $midi_out->panic;
        for my $chan (0 .. 15) {
            for my $n (0 .. 127) {
                $midi_out->note_off($chan, $n, 0);
            }
        }
    }
    catch ($e) {
        warn "Can't halt the MIDI out device: $e\n" if $opt{verbose};
    }
}

sub velocity ($min, $max, $offset) {
    return $offset + int(rand($max - $min + 1)) + $min;
}

sub populate ($p, $count) {
    my $motif = $p->motifs->[int rand $p->motifs->@*]; # TODO something clever?
    say "$count => ", ddc $motif if $opt{verbose};
    $p->queue([
        map { +{
            pitch    => $p->voice->rand,
            duration => $_,
            velocity => velocity(-10, 10, 110),
        } } @$motif
    ]);
    # compute the onsets
    my $tally = 0;
    my @ons = ($tally);
    for my $note ($p->queue->@[0 .. $p->queue->@* - 1]) {
        my $on = dura_size($note->{duration}) * DIVISIONS;
        $tally += $on;
        push @ons, $tally;
        $note->{on}  = $count + $tally - $on;
        $note->{off} = $note->{on} + $on * $p->gate; # scale the DURATION
    }
    $p->onsets([ map { $count + $_ } @ons ]);
    say 'Onsets: ', ddc $p->onsets if $opt{verbose};
    say 'Queue: ', ddc $p->queue if $opt{verbose};
    $p->index(0); # reset the queue index
}

sub on ($p, $count) {
    # if we are on a beat onset, note_on!
    if (defined $p->onsets->[$p->index] && $p->onsets->[$p->index] == $count) {
        my $n = $p->queue->[$p->index];
        say 'ON: ', $p->{channel}, ', ', $p->index, ", $count, ", ddc $n if $opt{verbose};
        if ($n) {
            $midi_out->note_on(
                $p->{channel},
                $n->{pitch},
                $n->{velocity},
            );
            # this note now owns this pitch on this channel
            $voice_owner{ $p->{channel} }{ $n->{pitch} } = refaddr($n);
        }
        else {
            warn "WARNING: No note to play?\n\n";
        }
        $p->increment_index;
    }
}

sub off ($p, $count) {
    for my $n (grep { $_->{off} <= $count && !$_->{off_sent} } $p->queue->@*) {
        $n->{off_sent} = 1; # don't re-check this note again

        my $owner = $voice_owner{ $p->{channel} }{ $n->{pitch} } // -1;
        if ($owner == refaddr($n)) {
            say 'OFF: ', $p->{channel}, ", $count, ", ddc $n if $opt{verbose};
            $midi_out->note_off($p->{channel}, $n->{pitch}, 0);
            delete $voice_owner{$p->{channel}}{$n->{pitch}};
        }
        else {
            say 'SKIPPED OFF (pitch reused): ', $p->{channel}, ", $count, ", ddc $n if $opt{verbose};
        }
    }
}

sub needs_more ($p, $count) {
    return 0 unless $p->index >= $p->queue->@*; # all notes triggered...
    my $max_off = 0;
    $max_off = $_->{off} > $max_off ? $_->{off} : $max_off for $p->queue->@*;
    return $count >= $max_off; # ...AND all have finished ringing
}

sub start_sequencer {
    return if defined $timer_id; # already running
    die "No parts configured\n" unless @parts;

    open_midi();
    send_program_changes();

    $ticks      = 0;
    $beat_count = 0;

    for my $part (@parts) {
        $part->index(0);
        $part->queue([]);
        $part->onsets([]);
    }

    $timer_id = Mojo::IOLoop->recurring($clock_interval => sub {
        $midi_out->clock;
        $ticks++;
        if ($ticks % $tick_div == 0) {
            off($_, $beat_count) for @parts;
            my $i = 0;
            for my $part (@parts) {
                my $idx = $i++;
                next if exists $muted_parts{$idx};
                populate($part, $beat_count) if needs_more($part, $beat_count);
                on($part, $beat_count);
            }
            $beat_count++;
        }
    });
}

sub stop_sequencer {
    return unless defined $timer_id;
    Mojo::IOLoop->remove($timer_id);
    undef $timer_id;
    panic_all();
    try {
        $midi_out->stop;
        $midi_out->close_port;
    }
    catch ($e) {
        warn "Error closing MIDI port: $e\n" if $opt{verbose};
    };
    undef $midi_out;
}

sub known_ports {
    my $device = RtMidiOut->new;
    return [
        map { $device->get_port_name($_) }
            sort { $a <=> $b } keys $device->get_all_port_nums->%*
    ];
}

sub normalize_to_pool ($arr, $pool) {
    if ($arr->@* != $pool->@*) {
        my @w;
        for my $n (0 .. $pool->$#*) {
            push @w, $arr->[$n] // 0;
        }
        $arr = \@w;
    }
    return $arr;
}


#################################################
#
#  Routes
#
#################################################

get '/' => sub ($c) {
    my %used_channels;
    my @known_ports = known_ports()->@*;
    push @known_ports, 'fluidsynth' unless grep { $_ =~ /fluid/i } @known_ports;
    for my $i (0 .. $#parts) {
        # don't block the channel of the unit currently being edited
        next if defined $edit{edit_part} && $i == $edit{edit_part};
        $used_channels{ $parts[$i]->{channel} } = 1;
    }
    $c->stash(
        opt           => \%opt,
        parts         => \@parts,
        choices       => \%choices,
        running       => defined($timer_id) ? 1 : 0,
        edit          => \%edit,
        used_channels => \%used_channels,
        saved         => $saved_parts,
        ports         => \@known_ports,
        muted         => \%muted_parts,
    );
    $c->render('index');
} => 'index';

post '/settings' => sub ($c) {
    return $c->redirect_to('/') if defined $timer_id; # don't change while running

    my $v = $c->req->params->to_hash;
    $opt{port} = $v->{port} if defined $v->{port};
    $opt{base} = $v->{base} if defined $v->{base};
    if ($v->{bpm}) {
        $opt{bpm} = $v->{bpm} + 0;
        recompute_timing();
    }
    $opt{verbose} = $v->{verbose} ? 1 : 0;

    $c->flash(message => 'Settings saved');
    $c->redirect_to('/');
} => 'settings';

post '/parts' => sub ($c) {
    return $c->redirect_to('/') if defined $timer_id; # don't add while running

    my $v = $c->req->params->to_hash;

    my %params;
    $params{channel}      = ($v->{channel} // 0) + 0;
    $params{name}         = $v->{name} || 'part';
    $params{patch}        = $v->{patch} // 0;
    $params{gate}         = $v->{gate} // 1;
    $params{volume}       = $v->{volume} // 100;
    $params{motif_num}    = $v->{motif_num} || 4;
    $params{scale}        = $v->{scale} || 'major';
    $params{octave}       = $v->{octave} // 4;
    $params{size}         = $v->{size} || 4;
    $params{pool}         = $choices{pool}{ $v->{pool} || 'wn' };
    $params{weights}      = [ split /\s+/, ($v->{weights} || (join ' ', ('1') x $params{pool}->@*)) =~ s/^\s+|\s+$//gr ];
    $params{groups}       = [ split /\s+/, ($v->{groups}  || (join ' ', ('1') x $params{pool}->@*)) =~ s/^\s+|\s+$//gr ];
    $params{pitches_name} = $v->{pitches};
    $params{pitches}      = [
        $choices{pitches}{ $v->{pitches} || '1 octave' }->(
            $opt{base}, $params{octave}, $params{scale}
        )
    ];
    $params{intervals_name} = $v->{intervals};
    $params{intervals}      = $choices{intervals}{ $v->{intervals} || '' };

    $params{weights} = normalize_to_pool($params{weights}, $params{pool});
    $params{groups}  = normalize_to_pool($params{groups}, $params{pool});

    if (defined $v->{edit_part}) {
        my $part = $parts[ $v->{edit_part} ];
        splice(@parts, $v->{edit_part}, 1, Music::VoicePhrase->new(%params));
        $part->clear_voice;
        %edit = ();
        $c->flash(message => 'Unit ' . ($v->{edit_part} + 1) . ' updated');
    }
    else {
        push @parts, Music::VoicePhrase->new(%params); #, verbose => 1);
        $c->flash(message => 'Unit ' . scalar(@parts) . ' appended');
    }

    $c->redirect_to('/');
} => 'parts';

post '/clear' => sub ($c) {
    return $c->redirect_to('/') if defined $timer_id;
    @parts = ();
    %edit = ();
    %muted_parts = ();
    $c->redirect_to('/');
} => 'clear';

post '/start' => sub ($c) {
    eval { start_sequencer() };
    $c->flash(error => $@) if $@;
    $c->redirect_to('/');
} => 'start';

post '/stop' => sub ($c) {
    stop_sequencer();
    $c->redirect_to('/');
} => 'stop';

post '/edit' => sub ($c) {
    return $c->redirect_to('/') if defined $timer_id; # don't change while running
    my $v = $c->req->params->to_hash;
    $edit{$_} = $v->{$_} for ($choices{parameters}->@*, 'edit_part');
    $c->flash(message => 'Now editing part ' . ($edit{edit_part} + 1));
    $c->redirect_to('/');
} => 'edit';

get '/cancel' => sub ($c) {
    %edit = ();
    $c->redirect_to('/');
} => 'cancel';

post '/delete' => sub ($c) {
    return $c->redirect_to('/') if defined $timer_id; # don't change while running
    my $v = $c->req->params->to_hash;
    splice(@parts, $v->{delete_part}, 1);
    %edit = ();
    $c->flash(message => 'Deleted part ' . ($v->{delete_part} + 1));
    $c->redirect_to('/');
};

post '/cycle' => sub ($c) {
    stop_sequencer();
    system('pkill -9 fluidsynth');
    my @cmd = ('fluidsynth');
    # push @cmd, '-v' if $opt{verbose};
    push @cmd, ('-m', 'coremidi', '-g', '1.3', $ENV{HOME} . '/Music/soundfont/FluidR3_GM.sf2');
    my $pid = open2($fluid_out, $fluid_in, @cmd);
    $fluid_in->autoflush(1);
    undef $midi_out;
    try {
        open_midi();
    }
    catch ($e) {
        $c->flash(error => "Can't cycle fluidsynth");
        return $c->redirect_to('/');
    }
    send_program_changes();
    $c->flash(message => 'Fluidsynth cycled');
    $c->redirect_to('/');
} => 'cycle';

post '/save' => sub ($c) {
    my $v = $c->req->params->to_hash;
    my @bits;
    my $params;
    for my $part (@parts) {
        $params = { map { $_ => $part->$_ } $choices{parameters}->@* };
        push @bits, $params;
    }
    $saved_parts->{ $v->{save_parts} } = \@bits;
    store $saved_parts, SAVED;
    $c->flash(message => 'Unit set saved as ' . $v->{save_parts});
    $c->redirect_to('/');
} => 'save';

post '/load' => sub ($c) {
    my $v = $c->req->params->to_hash;
    @parts = ();
    push @parts, Music::VoicePhrase->new($_) for $saved_parts->{ $v->{load_parts} }->@*;
    $c->flash(message => 'Unit set loaded: ' . $v->{load_parts});
    $c->redirect_to('/');
} => 'load';

post '/mute' => sub ($c) {
    return $c->redirect_to('/') if defined $timer_id; # don't change while running
    my $v = $c->req->params->to_hash;
    my $msg;
    for my $key (keys %$v) {
        next unless $key =~ /^mute_part_(\d+)$/;
        my $idx = $1;
        if ($v->{$key}) {
            $muted_parts{$idx} = 1;
            $msg = 'Muted part ' . ($idx + 1);
        } else {
            delete $muted_parts{$idx};
            $msg = 'Unmuted part ' . ($idx + 1);
        }
    }
    $c->flash(message => $msg);
    $c->redirect_to('/');
};

app->start;
