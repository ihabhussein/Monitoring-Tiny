#!/usr/bin/env perl

use v5.26;
use warnings;
use JSON;
use POSIX qw(strftime);
use IO::Socket;

my $data_start = tell DATA;

sub base_data {
    my $hostname = `hostname`;
    chomp $hostname;
    return (timestamp => time, host => $hostname);
};

my %ops = (
    status => sub {
        my @lines = map {s/\s+//; $_} `/usr/sbin/iostat -dC -c2`;
        my @D = split /\s+/, $lines[0]; pop @D;
        my @F = split /\s+/, $lines[-1];

        my ($i, $data) = (0, {});
        for (@D) {
            $data->{$_} = {
                kpt => 0+$F[$i++],
                tps => 0+$F[$i++],
                mps => 0+$F[$i++],
            };
        };
        return {
            &base_data,
            IO => $data,
            CPU => {user => 0+$F[-3], system => 0+$F[-2], idle => 0+$F[-1]},
        };
    },
    df => sub {
        my $data;
        for (`/bin/df -m`) {
            my @F = split /\s+/;
            push @$data, {
                filesystem => $F[0],
                size       => 0+$F[1],
                used       => 0+$F[2],
                available  => 0+$F[3],
                mount      => $F[-1],
            } if $F[-1] =~ m(^/) && $F[1] =~ /\d+/ && $F[1] > 0;
        };
        return {&base_data, disks => $data};
    },
    zfs => sub {
        my ($cur, $header, $data);
        for (`/sbin/zpool status`) {
            if (/^ *pool: *(.+)/) {
                $cur = $data->{$1} = {};
            } elsif (/^ *([^:]+):\s*(.*)/) {
                $cur->{$header = $1} = $2;
            } else {
                $cur->{$header} .= $_;
            };
        };
        return {&base_data, pools => $data};
    },
    packages => sub {
        my $data = [
            map {chomp; [split /\s+/, $_, 3]} `/usr/sbin/pkg version -vRl'<'`
        ];
        return {&base_data, packages => $data};
    },
);

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
<h1></h1>
<div>
    <figure>
        <figcaption>CPU%</figcaption>
        <canvas id="cpu"></canvas>
    </figure>
    <figure>
        <figcaption>I/O</figcaption>
        <canvas id="io"></canvas>
    </figure>
</div>
<div id="df"></div>

<script>
function Chart(selector, options) {
    let limits = (series, cb) => {
        series.forEach(d => {
            min = Math.min(...d.map(cb), Infinity);
            max = Math.max(...d.map(cb), -Infinity);
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
        [options.xAxis.min, options.xAxis.max] = limits(series, el => el[0]);
        [options.yAxis.min, options.yAxis.max] = [0, limits(series, el => el[1])[1]];

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
    let fillText = (s, x, y) => ctx.fillText(s, (x - options.xAxis.min) * xx, (y - options.yAxis.min) * yx);

    let ticks = () => {
        ctx.save();
        ctx.setLineDash([3, 3]);
        options.yAxis.ticks = Math.round(options.yAxis.max * 10) /100;

        ctx.beginPath();
        for (let y = options.yAxis.min + options.yAxis.ticks; y <= options.yAxis.max; y += options.yAxis.ticks) {
            moveTo(options.xAxis.min, y);
            lineTo(options.xAxis.max, y);
        };
        ctx.stroke();

        ctx.scale(1, -1);
        ctx.textBaseline = 'middle';
        ctx.textAlign = 'right';
        for (let y = options.yAxis.min; y <= options.yAxis.max; y += options.yAxis.ticks) {
            fillText(y, options.xAxis.min, -y);
        };

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

    this.plot = options => {
        ctx.clearRect(0, 0, W, H);
        setup(options.lines.map(d => d.data));
        axes();
        ticks();

        let i = 0;
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
    document.querySelector('h1').innerText = data.host;
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
        let lines = [];
        for (let x in data.IO) {
            if (!(x in diskio)) diskio[x] = [];
            diskio[x].push([data.timestamp, data.IO[x].mps]);
            while (diskio[x].length > 20) diskio[x].shift();
            lines.push({data: diskio[x]});
        };
        new Chart('#io', {lines: lines, xAxis: {title: 'Time'}, yAxis:{title: 'MB/s'}});
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
