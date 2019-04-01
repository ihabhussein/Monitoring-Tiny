#!/usr/bin/env perl

use v5.26;
use warnings;
use JSON;
use POSIX qw(strftime);
use IO::Socket;


my $data_start = tell DATA;
my %ops = (
    status      => \&status,
    df          => \&df,
    zfs         => \&zfs,
    packages    => \&packages,
);

sub status {
    my %data = (timestamp => time);

    my @lines = map {s/\s+//; $_} `/usr/sbin/iostat -dC -c2`;
    my @D = split /\s+/, $lines[0]; pop @D;
    my @F = split /\s+/, $lines[-1];
    my $i = 0;

    for (@D) {
        $data{IO}{$_} = {
            kpt => 0+$F[$i++],
            tps => 0+$F[$i++],
            mps => 0+$F[$i++],
        };
    };

    $data{CPU} = {
        user    => 0+$F[-3],
        system  => 0+$F[-2],
        idle    => 0+$F[-1],
    };

    return \%data;
};

sub df {
    my %data = (timestamp => time);

    for (`/bin/df -m`) {
        my @F = split /\s+/;
        push @{$data{DISK}}, {
            filesystem => $F[0],
            size       => 0+$F[1],
            used       => 0+$F[2],
            available  => 0+$F[3],
            mount      => $F[-1],
        } if $F[-1] =~ m(^/) && $F[1] =~ /\d+/ && $F[1] > 0;
    };

    return \%data;
}

sub zfs {
    my ($cur, $header, %data) = ({}, '');

    for (`/sbin/zpool status`) {
        if (/^ *pool: *(.+)/) {
            $cur = $data{$1} = {};
        } elsif (/^ *([^:]+):\s*(.*)/) {
            $cur->{$header = $1} = $2;
        } else {
            $cur->{$header} .= $_;
        };
    };

    return \%data;
}

sub packages {
    if (-x '/usr/sbin/pkg') {  # FreeBSD
        return [
            map {[$_, '', '']}
            `/usr/sbin/pkg version -vRl '<'`
        ];
    };

    if (-x '/usr/bin/apt-get') {  # Debian, Ubuntu
        return [
            map {[$_, '', '']}
            `/usr/bin/apt list --upgradable | /bin/grep -v Listing`
        ];
    };

    if (-x '/usr/local/bin/brew') {  # macOS
        return [
            map {/(\S+)\s\(([^)]+)\)\s+<\s+(\S+)/; [$1, $2, $3]}
            `/usr/local/bin/brew outdated -v`
        ];
    };

    return [];  # Other...
};

sub respond {
    my ($client) = @_;
    my $req = {};

    # Read request line
    {
        local $/ = "\r\n";
        local $_ = <$client>;
        if (/(\w+)\s*(.+?)\s*HTTP\/(\d.\d)/) {
            chomp;
            $req->{request} = $_;
            $req->{method} = uc($1);
            $req->{url} = $2;
            $req->{version} = $3;
        };
    }

    # Generate response
    my $s = substr $req->{url}, 1;
    my $res = {
        status => 200,
        headers => {'Content-type' => 'application/json'},
        text => '{}',
    };

    if ($req->{method} eq 'GET') {
        if ($req->{url} eq '/') {
            local $/;
            $res->{headers}{'Content-type'} = 'text/html';
            seek DATA, $data_start, 0;
            $res->{text} = <DATA>;
        } elsif (defined $ops{$s}) {
            $res->{text} = encode_json($ops{$s}());
        } else {
            $res->{status} = 404;                                    # Not Found
        }
    } else {
        $res->{status} = 405;                               # Method Not Allowed
    };
    $res->{headers}{'Content-length'} = length($res->{text});

    # Send the response
    $client->printf("HTTP/%s %d  \r\n", $req->{version}, $res->{status});
    $client->printf("%s: %s\r\n", $_, $res->{headers}{$_})
        for keys %{$res->{headers}};
    $client->printf("\r\n%s", $res->{text});

    # Log the request
    printf "%s - - [%s] \"%s\" %d %d\n",
        $client->sockhost(),
        strftime('%d/%b/%Y:%H:%M:%S %z', localtime),
        $req->{request},
        $res->{status},
        $res->{headers}{'Content-length'}
    ;
}


if (@ARGV == 1) {
    if (defined $ops{$ARGV[0]}) {
        say encode_json($ops{$ARGV[0]}());
    } else {
        my $server = IO::Socket::INET->new(
            Proto => 'tcp', LocalAddr => $ARGV[0], Listen => SOMAXCONN,
        ) or die "Unable to create server socket: $!";

        while (my $client = $server->accept) {
            respond($client); $client->close;
        };
    };
} else {
    print "Usage:\n\t$0 address:port\n";
    print "\t$0 $_\n" for keys %ops;
};

__DATA__
<html lang="en">
<head>
<meta charset="utf-8">
<style>
    body {
        font-family: system-ui,-apple-system, BlinkMacSystemFont, "Segoe UI", "Roboto";
        background-color: #353535;
        color: #dddddd;
    }
    figure {
        display: inline-block; border: 1px solid lightgray;
        width: fit-content; padding: 0.25rem;
    }
    figcaption {text-align: center;}
    #io {width: 480px; height: 320px;}
    #cpu {width: 160px; height: 320px;}
    canvas.df {width: 160px; height: 160px; font-size: 2rem;}
</style>
</head>
<body>
<div id="df">
    <figure>
        <figcaption>CPU%</figcaption>
        <canvas id="cpu"></canvas>
    </figure>
    <figure>
        <figcaption>I/O</figcaption>
        <canvas id="io"></canvas>
    </figure>
</div>

<script>
function Chart(selector, options) {
    let isObject = x => x && typeof x === 'object' && !Array.isArray(x);

    let assign2 = (target, ...sources) => {
        sources.forEach(s => {
            for (let k in s) {
                if (isObject(s[k])) {
                    if (!isObject(target[k])) target[k] = {};
                    assign2(target[k], s[k]);
                } else {
                    target[k] = s[k];
                };
            };
        });
        return target;
    };

    let limits = (series, min, max, cb) => {
        series.forEach(d => {
            min = Math.min(...d.map(cb), min);
            max = Math.max(...d.map(cb), max);
        });
        return [min, max];
    };

    let canvas = document.querySelector(selector);
    let style = window.getComputedStyle(canvas);
    let ctx = canvas.getContext('2d');

    let colors = ['orange', 'limegreen', 'red', 'purple',];
    let W = canvas.width = canvas.clientWidth, H = canvas.height = canvas.clientHeight;
    let mx = 40, my = 40;  // FIXME
    let xx = 0, yx = 0;

    let setup = (series) => {
        [options.xAxis.min, options.xAxis.max] = limits(series, options.xAxis.min, options.xAxis.max, el => el[0]);
        [options.yAxis.min, options.yAxis.max] = limits(series, options.yAxis.min, options.yAxis.max, el => el[1]);

        xx = (W - 2 * mx) / (options.xAxis.max - options.xAxis.min);
        yx = (H - 2 * my) / (options.yAxis.max - options.yAxis.min);

        ctx.translate(mx, H - my);
        ctx.scale(1, -1);
        ctx.textAlign = 'center';
        ctx.lineWidth = 1;
        ctx.lineJoin = 'round';
        ctx.font = style.font;
        ctx.fillStyle = ctx.strokeStyle = style.color;

        ctx.restore();
    };

    let axes = () => {
        ctx.save();
        ctx.beginPath();

        moveTo(options.xAxis.min, options.yAxis.max);
        lineTo(options.xAxis.min, options.yAxis.min);
        lineTo(options.xAxis.max, options.yAxis.min);
        ctx.stroke();

        ctx.scale(1, -1);
        ctx.textBaseline = 'bottom';

        // x-axis title
        ctx.fillText(options.xAxis.title, W / 2 - mx, my);

        // y-axis title
        ctx.rotate(-Math.PI / 2);
        ctx.textBaseline = 'top';
        ctx.fillText(options.yAxis.title, H / 2 - my, -mx);

        ctx.restore();
    };

    let moveTo = (x, y) => ctx.moveTo((x - options.xAxis.min) * xx, (y - options.yAxis.min) * yx);
    let lineTo = (x, y) => ctx.lineTo((x - options.xAxis.min) * xx, (y - options.yAxis.min) * yx);
    let drawRect = (x, y, w, h) => {
        ctx.strokeRect((x - options.xAxis.min) * xx, (y - options.yAxis.min) * yx, w * xx, h * yx);
        ctx.fillRect((x - options.xAxis.min) * xx, (y - options.yAxis.min) * yx, w * xx, h * yx);
    };
    let fillText = (s, x, y) => ctx.fillText(s, (x - options.xAxis.min) * xx, (y - options.yAxis.min) * yx);

    let ticks = () => {
        ctx.save();
        ctx.setLineDash([3, 3]);

        ctx.beginPath();
        if (options.xAxis.ticks > 0) {
            for (let x = options.xAxis.min + options.xAxis.ticks; x <= options.xAxis.max; x += options.xAxis.ticks) {
                moveTo(x, options.yAxis.min);
                lineTo(x, options.yAxis.max);
            }
        }
        if (options.yAxis.ticks > 0) {
            for (let y = options.yAxis.min + options.yAxis.ticks; y <= options.yAxis.max; y += options.yAxis.ticks) {
                moveTo(options.xAxis.min, y);
                lineTo(options.xAxis.max, y);
            }
        }
        ctx.stroke();

        ctx.scale(1, -1);
        if (options.xAxis.ticks > 0) {
            ctx.textBaseline = 'top';
            for (let x = options.xAxis.min; x <= options.xAxis.max; x += options.xAxis.ticks) {
                fillText(x, x, options.yAxis.min);
            }
        }
        if (options.yAxis.ticks > 0) {
            ctx.textBaseline = 'middle';
            ctx.textAlign = 'right';
            for (let y = options.yAxis.min; y <= options.yAxis.max; y += options.yAxis.ticks) {
                fillText(y, options.xAxis.min - 2, -y);
            };
        }

        ctx.restore();
    };

    let plotLine = (data, color, fill) => {
        if (data.length === 0) return;
        ctx.save();
        ctx.strokeStyle = color;
        ctx.lineWidth = 3;

        ctx.beginPath();
        moveTo(data[0][0], data[0][1]);
        data.forEach(el => lineTo(el[0], el[1]));
        ctx.stroke();

        if (fill) {
            lineTo(data[data.length - 1][0], options.yAxis.min);
            lineTo(data[0][0], options.yAxis.min);
            ctx.closePath();

            let grd = ctx.createLinearGradient(0, 3 * H, 0, 0);
            grd.addColorStop(0.0, color);
            grd.addColorStop(1.0, style.backgroundColor);
            ctx.fillStyle = grd;
            ctx.globalCompositeOperation = 'destination-over';
            ctx.fill();
        };

        ctx.restore();
    };

    let plotBar = (data, color, fill, n, idx) => {
        if (data.length === 0) return;
        if (!n || idx >= n) return;
        ctx.save();
        ctx.strokeStyle = color;
        ctx.lineWidth = 1;

        let grd = ctx.createLinearGradient(0, H, 0, -H);
        grd.addColorStop(0.0, color);
        grd.addColorStop(1.0, style.backgroundColor);
        ctx.fillStyle = grd;
        ctx.globalCompositeOperation = 'destination-over';

        let i = 0,
            w = options.xAxis.ticks / (n + 1),
            x = w * (idx - n / 2);
        data.forEach(el => {
            x += options.xAxis.ticks;
            drawRect(x, 0, w, el[1]);
        });

        ctx.restore();
    };

    this.plot = options => {
        options = assign2({
            lines: [], bars: [],
            xAxis: {title: '', min: Infinity, max: -Infinity, ticks: undefined},
            yAxis: {title: '', min: Infinity, max: -Infinity, ticks: undefined},
        }, options);

        ctx.clearRect(0, 0, W, H);
        setup([...options.lines.map(d => d.data), ...options.bars.map(d => d.data)]);
        axes();
        ticks();

        let i = 0;
        options.bars.forEach((d, idx) => plotBar(d.data, d.color || colors[i++ % colors.length], d.fill, options.bars.length, idx));
        options.lines.forEach(d => plotLine(d.data, d.color || colors[i++ % colors.length], d.fill));
    };

    this.plot(options);
};

function LinearGauge(selector, options = {}) {
    let canvas = document.querySelector(selector);
    let style = window.getComputedStyle(canvas);
    let ctx = canvas.getContext('2d');

    options.max = options.max || 100;
    options.colors = options.colors || ['green', 'yellow', 'orange', 'red',];
    let W = canvas.width = canvas.clientWidth, H = canvas.height = canvas.clientHeight;
    let mx = 40, my = 40;  // FIXME
    let xx = (W - 2 * mx), yx = (2 * my - H) / options.max;

    ctx.translate(mx, H - my);
    ctx.font = style.font;
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'right';
    ctx.lineWidth = 3;
    ctx.strokeStyle = ctx.fillStyle = window.getComputedStyle(canvas).color;

    ctx.moveTo(0, 0); ctx.lineTo(xx, 0);
    ctx.moveTo(0, options.max * yx); ctx.lineTo(xx, options.max * yx);
    ctx.stroke();
    ctx.fillText(options.max, -3, options.max * yx);
    ctx.fillText('0', -3, 0);

    this.plot = (...data) => {
        if (data.length === 0) return;
        ctx.clearRect(0, 0, xx, options.max * yx);

        let sum = data.reduce((a, v) => a + v, 0);
        let i = 0, y = 0, s = options.max * yx / sum;
        data.forEach(el => {
            el *= s;
            ctx.fillStyle = options.colors[i++ % options.colors.length];
            ctx.fillRect(0, y, xx, el);
            y += el;
        });
    };

    this.plot(options.data);
};

function DialGauge(selector, options = {}) {
    let angle = v => 2 * Math.PI * (v - 0.25);

    let canvas = document.querySelector(selector);
    let ctx = canvas.getContext('2d');
    let style = window.getComputedStyle(canvas);
    let W = canvas.width = canvas.clientWidth, H = canvas.height = canvas.clientHeight;
    let R = (W < H? W: H) / 2 - 20;
    let locale = document.documentElement.lang || 'en';
    ctx.translate(W / 2, H / 2);

    ctx.lineWidth = 20;
    ctx.strokeStyle = options.color || 'red';
    ctx.lineCap = 'round';
    ctx.fillStyle = style.color;
    ctx.font = style.font;
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'center';

    this.plot = value => {
        if (!value) return;
        ctx.clearRect(-W / 2, -H / 2, W / 2, H / 2);

        value /= (options.max || 100);
        ctx.beginPath();
        ctx.arc(0, 0, R, angle(0), angle(value));
        ctx.stroke();
        ctx.fillText(value.toLocaleString('en', {style: 'percent'}), 0, 0);
    };

    this.plot(options.value);
};

let getId = s => `df_${s.replace(/\//g, '_')}`;
let cpu = new LinearGauge('#cpu', {colors: ['green', 'red', '#353535']});
let df = {}, diskio = {};

fetch('/df').then(r => r.json()).then(data => {
    let div = document.querySelector('#df');
    data.DISK.forEach(x => {
        let id = getId(x.mount);
        let fig = document.createElement('figure');
        fig.innerHTML = `<figcaption>${x.mount}</figcaption><canvas id="${id}" class="df"></canvas>`;
        div.appendChild(fig);
        df[id] = new DialGauge(`#${id}`);
    });
});

setInterval(() => {
    fetch('/status').then(r => r.json()).then(data => {
        console.log(data);
        let lines = [];
        for (let x in data.IO) {
            if (!(x in diskio)) diskio[x] = [];
            diskio[x].push([data.timestamp, data.IO[x].mps]);
            lines.push(diskio[x]);
        };
        new Chart('#io', {lines: lines, xAxis: {}, yAxis:{}});
        cpu.plot(Number(data.CPU.user), Number(data.CPU.system), Number(data.CPU.idle));
    })
}, 5000);

setInterval(() => {
    fetch('/df').then(r => r.json()).then(data =>
        data.DISK.forEach(x => df[getId(x.mount)].plot(x.used * 100 / x.size))
    )
}, 13000);
</script>
</body>
</html>
