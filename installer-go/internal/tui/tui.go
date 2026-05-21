package tui

import (
	"bufio"
	"fmt"
	"os"
	"strings"

	"github.com/fatih/color"
)

var (
	colTitle = color.New(color.FgHiCyan, color.Bold)
	colStep  = color.New(color.FgHiYellow)
	colOK    = color.New(color.FgHiGreen, color.Bold)
	colErr   = color.New(color.FgHiRed, color.Bold)
	colInfo  = color.New(color.FgWhite)
)

func Banner(version string) {
	fmt.Println()
	colTitle.Println("╔══════════════════════════════════════════════════════════╗")
	colTitle.Printf( "║  PAINEL OFFICE XTREAM — Instalador v%-22s║\n", version)
	colTitle.Println("╚══════════════════════════════════════════════════════════╝")
	fmt.Println()
}

func Step(format string, a ...any) {
	colStep.Print("→ ")
	colInfo.Printf(format+"\n", a...)
}

func Success(format string, a ...any) {
	colOK.Print("✓ ")
	colInfo.Printf(format+"\n", a...)
}

func Fatal(err error) {
	colErr.Println("✗ ERRO:", err)
	os.Exit(1)
}

func Prompt(label string) string {
	colInfo.Print(label)
	r := bufio.NewReader(os.Stdin)
	s, _ := r.ReadString('\n')
	return strings.TrimSpace(s)
}

func PromptDefault(label, def string) string {
	s := Prompt(fmt.Sprintf("%s [%s]: ", label, def))
	if s == "" {
		return def
	}
	return s
}

func Confirm(label string) bool {
	s := Prompt(label + " (y/n): ")
	s = strings.ToLower(strings.TrimSpace(s))
	return s == "y" || s == "yes" || s == "s" || s == "sim"
}
