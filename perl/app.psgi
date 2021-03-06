use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/extlib/lib/perl5";
use lib "$FindBin::Bin/lib";
use File::Basename;
use Plack::Builder;
use Isu4Qualifier::Web;
use File::Temp qw/tempdir/;
use JSON::XS;
use Cookie::Baker;
use Isu4Qualifier::Template;
use Isu4Qualifier::Model;
use WWW::Form::UrlEncoded::XS qw/parse_urlencoded build_urlencoded/;

my $root_dir = File::Basename::dirname(__FILE__);

my $_JSON = JSON::XS->new->utf8->canonical;
my $cookie_name = 'isu4_session';

local $Kossy::XSLATE_CACHE = 2;
local $Kossy::XSLATE_CACHE_DIR = tempdir(DIR=>-d "/dev/shm" ? "/dev/shm" : "/tmp");
local $Kossy::SECURITY_HEADER = 0;
my $app = Isu4Qualifier::Web->psgi($root_dir);
my $model = Isu4Qualifier::Model->new;

builder {
    #enable 'ReverseProxy';
    enable sub {
        my $mapp = shift;
        sub {
            my $env = shift;

            my ( $ip, ) = $env->{HTTP_X_FORWARDED_FOR} =~ /([^,\s]+)$/;
            $env->{REMOTE_ADDR} = $ip;

            my $cookie = crush_cookie($env->{HTTP_COOKIE} || '')->{$cookie_name};
            if ( $cookie ) {
               $env->{'psgix.session'} = +{parse_urlencoded($cookie)};
               $env->{'psgix.session.options'} = {
                   id => $cookie
               };
            }
            else {
                $cookie = '{}';
                $env->{'psgix.session'} = {};
                $env->{'psgix.session.options'} = {
                    id => '{}',
                    new_session => 1,
                };
            }

            my $res = $mapp->($env);

            my $cookie2 = build_urlencoded(%{$env->{'psgix.session'}});
            my $bake_cookie;
            if ($env->{'psgix.session.options'}->{expire}) {
                $bake_cookie = bake_cookie( $cookie_name, {
                    value => '{}',
                    path => '/',
                    expire => 'none',
                    httponly => 1 
                });
            }
            elsif ( $cookie ne $cookie2 ) {
                $bake_cookie = bake_cookie( $cookie_name, {
                    value => $cookie2,
                    path => '/',
                    expire => 'none',
                    httponly => 1 
                });
            }
            Plack::Util::header_push($res->[1], 'Set-Cookie', $bake_cookie) if $bake_cookie;
            $res;
        };
    };
    sub {
        my $env = shift;
        if ( $env->{PATH_INFO} eq '/' ) {
            my $flash = delete $env->{'psgix.session'}->{flash};
            return [200,['Content-Type'=>'text/htmlcharset=UTF-8'],[
                Isu4Qualifier::Template->get('base_before'),
                Isu4Qualifier::Template->get('index_before'),
                $flash ? q!<div id="notice-message" class="alert alert-danger" role="alert">!.$flash.q!</div>! : (),
                Isu4Qualifier::Template->get('index_after'),
                Isu4Qualifier::Template->get('base_after') 
                ]];
        }
        elsif ( $env->{PATH_INFO} eq '/hello' ) {
            return [200,['Content-Type'=>'text/htmlcharset=UTF-8'],["HelloWorld\n"]];
        }
        elsif ( $env->{PATH_INFO} eq '/mypage' ) {
            my $user_id = $env->{'psgix.session'}->{user_id};
            my $user = $model->user_id($user_id);
            if ($user) {
                my $last_login = $model->last_login($user_id);
                return [200,['Content-Type'=>'text/htmlcharset=UTF-8'],[
                    Isu4Qualifier::Template->get('base_before'),
                    Isu4Qualifier::Template->get('mypage_1'),
                    $last_login->{created_at},
                    Isu4Qualifier::Template->get('mypage_2'),
                    $last_login->{ip},
                    Isu4Qualifier::Template->get('mypage_3'),
                    $user->{login},
                    Isu4Qualifier::Template->get('mypage_4'),
                    Isu4Qualifier::Template->get('base_after')
                    ]];
            }
            $env->{'psgix.session'}->{flash} = 'You must be logged in';
            return [302,[Location=>"/"],[]];
        }
        elsif ( $env->{PATH_INFO} eq '/login' ) {
            my $input = $env->{'psgi.input'};
            $input->seek(0, 0);
            $input->read(my $chunk, 8192);
            my $params = +{parse_urlencoded($chunk)};
            my ($user, $err) = $model->attempt_login(
                $params->{login},
                $params->{password},
                $env->{REMOTE_ADDR} || '127.0.0.1'
            );
            if ($user && $user->{id}) {
                $env->{'psgix.session'}->{user_id} = $user->{id};
                return [302,[Location=>"/mypage"],[]];
            }
            if ($err eq 'locked') {
                $env->{'psgix.session'}->{flash} = 'This account is locked.';
            }
            elsif ($err eq 'banned') {
                $env->{'psgix.session'}->{flash} = q!You're banned.!;
            }
            else {
                $env->{'psgix.session'}->{flash} = q!Wrong username or password!;
            }
            return [302,[Location=>"/"],[]];
        }
        return $app->($env)
    }
};
