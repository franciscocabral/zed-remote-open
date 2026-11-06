# Homebrew formula for the local side (macOS and Linux): the listener and its installer.
#   brew tap franciscocabral/zed-remote-open https://github.com/franciscocabral/zed-remote-open
#   brew install zed-remote-open
#   zed-remote-open-setup
# The release job updates the version, the URLs and the checksums.
class ZedRemoteOpen < Formula
  desc "Open files of your SSH servers in the local Zed editor (local listener)"
  homepage "https://github.com/franciscocabral/zed-remote-open"
  url "https://github.com/franciscocabral/zed-remote-open/releases/download/v1.2.0/local-unix-installer.sh"
  version "1.2.0"
  sha256 "f46ae885c3a807cb0dd42b34d504cd58d20822be9d078ff3f4f4393930622704"

  depends_on "python@3.13"

  resource "listener" do
    url "https://github.com/franciscocabral/zed-remote-open/releases/download/v1.2.0/zed-listener.pyw"
    sha256 "d2fa5028eb35a1eb9625a607a304f06d554a3c95b6f55d4168d3d41fd27afd2e"
  end

  def install
    libexec.install "local-unix-installer.sh"
    resource("listener").stage { libexec.install "zed-listener.pyw" }
    python = Formula["python@3.13"].opt_bin/"python3.13"
    (bin/"zed-remote-open-setup").write <<~SH
      #!/bin/bash
      exec bash "#{libexec}/local-unix-installer.sh" -P "#{python}" "$@"
    SH
  end

  def caveats
    <<~TEXT
      Run this command to install and start the listener, and to set up SSH:
        zed-remote-open-setup
      Before "brew uninstall zed-remote-open", run:
        zed-remote-open-setup -u
    TEXT
  end

  test do
    assert_match "Usage", shell_output("#{bin}/zed-remote-open-setup -x 2>&1", 1)
  end
end
