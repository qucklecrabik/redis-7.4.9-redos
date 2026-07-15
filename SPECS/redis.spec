Name:           redis
Version:        7.4.9
Release:        1%{?dist}
Summary:        A persistent key-value database
License:        RSALv2 or SSPLv1
URL:            https://redis.io
Source0:        redis-7.4.9.tar.gz
Source1:        redis.conf
Source2:        redis.service

BuildRequires:  gcc, gcc-c++, make
BuildRequires:  openssl-devel
BuildRequires:  systemd-devel
BuildRequires:  jemalloc-devel
BuildRequires:  tcl
%{?systemd_requires}
BuildRequires:  systemd-rpm-macros

Requires(pre):  shadow-utils
Requires:       systemd

%description
Redis is an open source, advanced key-value store. It is often referred to
as a data structure server since keys can contain strings, hashes, lists,
sets, sorted sets, bitmaps and hyperloglogs. This build enables TLS and
systemd supervision support.

%prep
%setup -q -n redis-%{version}

%build
make %{?_smp_mflags} \
    BUILD_TLS=yes \
    USE_SYSTEMD=yes \
    MALLOC=jemalloc \
    PREFIX=%{_prefix}

%install
rm -rf %{buildroot}
make install \
    BUILD_TLS=yes \
    USE_SYSTEMD=yes \
    MALLOC=jemalloc \
    PREFIX=%{buildroot}%{_prefix}

install -d -m 0755 %{buildroot}%{_sysconfdir}/redis
install -d -m 0750 %{buildroot}%{_sharedstatedir}/redis
install -d -m 0750 %{buildroot}%{_localstatedir}/log/redis
install -d -m 0755 %{buildroot}%{_unitdir}

install -m 0640 %{SOURCE1} %{buildroot}%{_sysconfdir}/redis/redis.conf
install -m 0644 %{SOURCE2} %{buildroot}%{_unitdir}/redis.service

%pre
getent group redis >/dev/null || groupadd -r redis
getent passwd redis >/dev/null || \
    useradd -r -g redis -d %{_sharedstatedir}/redis -s /sbin/nologin \
    -c "Redis Database Server" redis
exit 0

%post
%systemd_post redis.service

%preun
%systemd_preun redis.service

%postun
%systemd_postun_with_restart redis.service

%files
%license LICENSE.txt
%doc 00-RELEASENOTES BUGS README.md
%{_bindir}/redis-server
%{_bindir}/redis-cli
%{_bindir}/redis-benchmark
%{_bindir}/redis-check-aof
%{_bindir}/redis-check-rdb
%{_bindir}/redis-sentinel
%{_unitdir}/redis.service
%config(noreplace) %attr(0640, redis, redis) %{_sysconfdir}/redis/redis.conf
%dir %attr(0755, root, root) %{_sysconfdir}/redis
%attr(0750, redis, redis) %dir %{_sharedstatedir}/redis
%attr(0750, redis, redis) %dir %{_localstatedir}/log/redis

%changelog
* Wed Jul 15 2026 L_Admin <l_admin@lab.corp> - 7.4.9-1
- Initial RPM build of Redis 7.4.9 for RED OS 8
