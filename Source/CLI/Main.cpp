#include "CLICommands.h"

int main (int argc, char* argv[])
{
    CLI::App app { "LowEnd Circuit - Desktop bass enhancer with harmonic coloration" };
    app.set_help_all_flag ("--help-all", "Show all help");

    // === process subcommand ===
    auto* processCmd = app.add_subcommand ("process", "Process an audio file (offline rendering)");

    auto processOpts = std::make_shared<lowend::cli::ProcessOptions>();

    processCmd->add_option ("-i,--input", processOpts->inputFile, "Input audio file (wav)")
        ->required()
        ->check (CLI::ExistingFile);
    processCmd->add_option ("-o,--output", processOpts->outputFile, "Output audio file (wav)")
        ->required();
    processCmd->add_option ("--preset", processOpts->preset, "Preset name (Gentle, LowEnd, Deep, Reset)");
    processCmd->add_option ("--lowend", processOpts->intensity, "LowEnd intensity 0-100")
        ->check (CLI::Range (0.0f, 100.0f));
    processCmd->add_option ("--body", processOpts->body, "Body amount 0-100")
        ->check (CLI::Range (0.0f, 100.0f));
    processCmd->add_option ("--mix", processOpts->mix, "Dry/Wet mix 0-100")
        ->check (CLI::Range (0.0f, 100.0f));
    processCmd->add_option ("--output-db", processOpts->outputDb, "Output gain in dB (-18 to 6)")
        ->check (CLI::Range (-18.0f, 6.0f));
    processCmd->add_flag ("--json", processOpts->jsonOutput, "Output result as JSON");

    processCmd->callback ([processOpts]() {
        return lowend::cli::runProcess (*processOpts);
    });

    // === list-presets subcommand ===
    auto* presetsCmd = app.add_subcommand ("list-presets", "List available presets");

    auto presetsJson = std::make_shared<bool> (false);
    presetsCmd->add_flag ("--json", *presetsJson, "Output as JSON");

    presetsCmd->callback ([presetsJson]() {
        return lowend::cli::runListPresets (*presetsJson);
    });

    // === info subcommand ===
    auto* infoCmd = app.add_subcommand ("info", "Show parameter information");

    auto infoJson = std::make_shared<bool> (false);
    infoCmd->add_flag ("--json", *infoJson, "Output as JSON");

    infoCmd->callback ([infoJson]() {
        return lowend::cli::runInfo (*infoJson);
    });

    // Parse and run
    try
    {
        app.parse (argc, argv);
    }
    catch (const CLI::ParseError& e)
    {
        return app.exit (e);
    }

    return 0;
}
