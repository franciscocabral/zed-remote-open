# Homebrew formula for the local side (macOS and Linux): the listener and its installer.
#   brew tap franciscocabral/zed-remote-open https://github.com/franciscocabral/zed-remote-open
#   brew install zed-remote-open
#   zed-remote-open-setup
# The release job updates the version, the URLs and the checksums.
class ZedRemoteOpen < Formula
  desc "Open files of your SSH servers in the local Zed editor (local listener)"
  homepage "https://github.com/franciscocabral/zed-remote-open"
  url "https://github.com/franciscocabral/zed-remote-open/releases/download/v1.1.0/local-unix-installer.sh"
  version "1.1.0"
  sha256 "89e2ac8c6331eeee643168df2cf78c3c6d6f9ae4ee9d794e22f7183f124cd390"

  depends_on "python@3.13"

  resource "listener" do
    url "https://github.com/franciscocabral/zed-remote-open/releases/download/v1.1.0/zed-listener.pyw"
    sha256 "292443c3bffb89db8cf8e9fab1f425f8f54ffd5e183f757c8d31bcc1648414eb"
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
